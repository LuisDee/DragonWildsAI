# Humanoid companion: what the dump says (routes 1 and 2, loot, speech)

Date: 2026-10-25. Source: UE4SS dump of the dedicated server, build **26161880** (UE 5.6, module `Dominion`), at `dumps/26161880/`. It also uses runtime facts already in `logs/mod/*.jsonl` (the `body_probe` runs of 12:42 UTC) and the Route 1 result in `docs/DISCOVERIES.md` ("ROUTE 1 WORKS").

This note **extends** `2026-10-25-dump-body.md` (AI stack, spawning, navigation, followers) and `2026-10-25-dump-chat-inventory.md` (chat hooks, inventory, interaction). It does not repeat them.

**References**
- `O:<n>` is a line in `UE4SS_ObjectDump.txt`.
- `CXX <file>:<n>` is a line in `CXXHeaderDump/<file>`. `DOM` means `CXXHeaderDump/Dominion.hpp`.
- `UHT <file>` is `UHTHeaderDump/Dominion/Public/<file>`, which holds the UFUNCTION/UPROPERTY specifiers.
- `LOG` is `logs/mod/mod_*.jsonl`.

**Confidence levels**
- **HIGH:** read directly from the dump or logs.
- **MEDIUM:** inferred from signatures and names plus standard UE5 behaviour.
- **LOW:** a plausible guess that must be tested.

---

## 0. Verdicts

1. **Route 1 (a player body driven by the server) is feasible as a "puppeted player". It is not feasible as a "native player".** HIGH for the split, MEDIUM for the puppet parts.
   - **Already proven:** a `BP_PlayerCharacter_C` under a plain `AIController` spawns, replicates, path-finds and animates on GFN.
   - **Not available:** the native player pipeline.
     - Loadout and inventory are owned by the controller.
     - Enhanced Input drives `UPlayerActionPerformer`.
     - Attacks and evades travel inside the packed movement stream (`Character:ServerMovePacked`, O:18778, carrying `EDomMoverActionTypeIndex` payloads). There is **no `Server_*` RPC for attack or evade** that we could inject.
     - On a server-only build, a `PlayerController` is never "local", so a connectionless PlayerController cannot drive the movement component (A.5).
   - **What remains is a lot.** The parts a client can see are mostly **replicated properties and multicasts on the pawn's own components**, which we can write from the server:
     - Armour: `CurrentBodyWearable` and the other wearable slots.
     - Held weapon: `HeldEquipmentActorRight` and `HeldEquipmentActorLeft`.
     - Appearance: `CustomizationSaveData`.
     - Emotes: `AuthoritativeEmoteIndex`.
     - Attack animation: `Multicast_PerformAttackOnSimulatedProxies`, or a generic montage multicast.
   - Effects in the world go through server APIs: damage (`DamageComponent:PredictDamage` + `ApplyDamageFromGameplayEffect`), health (`SetIsImmortal`) and loot (`MagneticComponent:BP_MagnetizeToPlayer`).
   - **Recommendation:** keep Route 1 as the primary body.
2. **Best Route 2 candidate: `BP_AI_1HMeleeBlackKnight_Character_C`, made friendly the same way the Kalphite friend is.**
   - Path: `/DowdunReach/Gameplay/AI/BlackKnightFaction/1HMeleeBlackKnight/BP_AI_1HMeleeBlackKnight_Character.BP_AI_1HMeleeBlackKnight_Character_C`. It is a runtime-verified spawn-point class (LOG `body_probe_director`).
   - The live `BP_AI_KalphiteFriend_Character_C` reported `is_confused=true`, `is_follower=true`, `PowerLevel=7`, `bSkipSpudStore=true`, with controller `BP_AI_KalphiteSoldier_Controller_C` (LOG `body_probe_class`, 12:42 UTC). **So the "friend" is an ordinary hostile AI in a confused-and-following state.** That state is reachable with `Confuse(Luis, true)` (HIGH).
   - Confused AI fight other AI: `UAIDataAsset.DamageMultiplerVsAIWhenConfused` (O:46647), `UConfuseGameplayEffectData.bShouldAgroPulse` and `AgroPulseRange` (O:51057-51058).
   - `SetSpecifiedTargetOverride(FJgxActorFacadeHandle)` (O:53453) aims it at a chosen enemy.
3. **Speech: `Client_ReceiveChatMessage` (O:45127) on every player's `PlayerChat`, with a crafted `FChatMessageData`.** Which name the client shows is the open question. The best bet is to register the companion's `CharacterGuid` with a name through `DisplayNameComponent:Server_RegisterCharacter` (O:52735) first (D).

---

## A. Route 1: player-class body driven by the server

### A.1 What the pawn takes from the controller and the PlayerState

The character holds almost all **combat and visual** components. The controller holds all **item storage**. HIGH (DOM:9893-9952, DOM:10211-10238).

| Need | Lives on | Path | Ref |
|---|---|---|---|
| Held weapon actors, worn armour meshes | **pawn** | `ADominionPlayerCharacter.PlayerEquipmentComponent` (`UPlayerEquipmentComponent`, BP `BP_Components_PlayerEquipment`) | DOM:9908, DOM:29689; O:72282 |
| Action routing (primary/secondary/special/evade per hand) | **pawn** | `PlayerActionPerformerComponent` (`UPlayerActionPerformer`) | DOM:9914, DOM:29196 |
| Melee attacks | **pawn** | `PlayerMeleeAttackComponent` (`UPlayerMeleeAttackComponent : UPlayerAttackComponent`) | DOM:9905, DOM:30176, DOM:29322; O:72279 |
| Ranged / combat magic | **pawn** | `PlayerRangedAttackComponent`, `PlayerCombatMagicComponent` | DOM:9924, DOM:9906 |
| Evade | **pawn** | `EvadeComponent` (`UPlayerEvadeComponent`) | DOM:9899, DOM:29757 |
| Health | **pawn** | `HealthComponent` (`UPlayerHealthComponent : UHealthFromAttributeComponent : UHealthComponent`) | DOM:9895, DOM:29917, DOM:23641; O:72269 |
| Incoming damage | **pawn** | `PlayerDamageComponent` (`UPlayerDamageComponent : UDamageComponent`) | DOM:9922, DOM:29588; O:72296 |
| Appearance | **pawn** | `PlayerCustomizationComponent` | DOM:9911, DOM:29562; O:72285 |
| Emotes | **pawn** | `PlayerEmotesComponent` | DOM:9918; O:72292 |
| Montage playback | **pawn** | `PlayerAnimationManagerComponent` (`UPlayerAnimationManager`) | DOM:9917; O:72291 |
| Item magnet (auto-loot radius) | **pawn** | `ItemMagnet` (`UItemMagnet`, only `MagnetRange`) | DOM:9903, DOM:25442 |
| Movement | **pawn** | `UDominionMovementComponent : UCharacterMovementComponent` (`GetDominionMovementComponent()`) | DOM:20581 |
| **Backpack** | **controller** | `ADominionPlayerController.InventoryComponent` / `GetInventory()` | DOM:10212 |
| **Personal inventory** | **controller** | `PersonalInventoryComponent` / `GetPersonalInventory()` | DOM:10213 |
| **Loadout (equipped items)** | **controller** | `LoadoutComponent` / `GetLoadout()` (`ULoadoutComponent : UInventoryWithLogComponent`) | DOM:10214, DOM:26227 |
| Inventory RPCs (move, craft, drop) | **controller** | `InventoryController` | DOM:10211 |
| Skills (levels) | **controller base** | `ADominionPlayerControllerBase.SkillComponent` | DOM:10359 |
| Chat | **controller** | `PlayerChatComponent` (BP name `PlayerChat`) | DOM:10233; CXX BP_PlayerController.hpp:11 |
| Auto-equip | **controller** | `AutoEquipComponent` | DOM:10238 |
| Identity | **PlayerState** | `ADominionPlayerState.OwnerGuid` (`FDomOwnerGuid`), `PlayerColor`, `PlatformData`, `DisplayNameComponent` | DOM:10401; O:54242 |

**How the pawn binds to the controller.** Each of these is a reflected handler that takes the new controller. HIGH for the signatures (UHT); MEDIUM that each casts to `ADominionPlayerController` and does nothing otherwise.
- `UPlayerEquipmentComponent.OwningController` (`ADominionPlayerController*`, O:63864) is set in `ReceiveControllerChanged(Pawn, OldController, NewController)` (O:63867).
- `UPlayerActionPerformer:SetupLoadoutDelegates(Pawn, OldController, NewController)` (O:63240) binds the action loadout to the controller's `ULoadoutComponent` events `OnHeldRightItemChanged`, `OnHeldLeftItemChanged` and so on (DOM:26229-26254).
- `ADominionPlayerCharacter` has `OnHeldRightItemChanged`/`OnBodyItemChanged`/... handlers (DOM:9997-10014) and `OnControllerRepReceived` (DOM:10010).
- `ULoadoutComponent:OnOwnerPossessedPawnChanged` / `HandleOnPawnChanged` (DOM:26258-26261) go the other way.

**Consequence.** Under an AIController, `OwningController` is null and no loadout events ever fire. The puppet therefore never equips anything through the normal path. This matches what Luis saw: a plain, unarmed character.

### A.2 Equipment system: where it lives and how to drive it without a loadout

`UPlayerEquipmentComponent` (DOM:29689; UHT PlayerEquipmentComponent.h) is **on the pawn**. All of its visible state is replicated from the server (`DOREPLIFETIME` list in UHT `Private/PlayerEquipmentComponent.cpp:94-100`). HIGH.

| Property | Type | Specifiers | Ref |
|---|---|---|---|
| `HeldEquipmentActorRight` | `AHeldEquipmentActor*` | Transient, ReplicatedUsing=`OnRep_HeldEquipmentActorRight` | O:63848, UHT :46 |
| `HeldEquipmentActorLeft` | `AHeldEquipmentActor*` | ReplicatedUsing=`OnRep_HeldEquipmentActorLeft` | O:63847 |
| `CurrentHeadWearable`, `CurrentBodyWearable`, `CurrentLegsWearable`, `CurrentCapeWearable` | `UWearableEquipmentData*` | ReplicatedUsing=`OnRep_Current*Wearable` | O:63859-63862 |
| `bHideHeadWearable` | bool | ReplicatedUsing | UHT :92 |
| `HeldRightSocketName`, `HeldLeftSocketName` | FName | (attach sockets) | O:63843 |

Getters: `GetHeldEquipmentActorRight/Left()`, `GetHeldEquipmentDataRight/Left()`, `GetRight/LeftHandEquipmentCategory()` (all BlueprintPure). Hide toggles: `BP_SetShouldHideRight/LeftHeldEquipment(Locker, bool)` (O:63901).

**Held equipment actor.** `AHeldEquipmentActor : AActor` (DOM:11123) has `bReplicates = true` and `RemoteRole = SimulatedProxy` in its constructor (UHT `Private/HeldEquipmentActor.cpp`). HIGH.
- Replicated fields: `HeldEquipmentActorID` (uint16), `HeldEquipmentItem` (`UHeldEquipmentItem*`), `HeldEquipmentData` (`UHeldEquipmentData*`, O:56570), and the magical/physical effect infos.
- Generic class: `/Game/Gameplay/Character/Player/Equipment/Held/BP_HeldEquipmentBase.BP_HeldEquipmentBase_C` (O:233506). Torch subclass: `BP_Torch_C` (O:233513).
- Each weapon's class: `UHeldEquipmentData.HeldEquipmentActorClass` (TSoftClassPtr, O:56635). Ranged weapons use `AHeldRangedEquipmentActor` (DOM:11171).

**Weapon data assets** (168 `HeldEquipmentData` loaded at idle; examples):
- Sword: `/DowdunReach/Gameplay/Character/Player/Equipment/Held/Sword/ITEM_Sword_Mithril.ITEM_Sword_Mithril` (O:213289)
- Mace: `.../Held/Mace/ITEM_Mace_Mithril.ITEM_Mace_Mithril` (O:213296)
- Greatsword: `/Game/Gameplay/Character/Player/Equipment/Held/GreatSword/ITEM_GreatSword_Iron.ITEM_GreatSword_Iron` (O:213292)
- Shortbow: `/Game/Gameplay/Character/Player/Equipment/Held/Bow/ITEM_Shortbow_Oak.ITEM_Shortbow_Oak` (O:225022)
- Staff: `/Game/Gameplay/Character/Player/Equipment/Held/Staff/ITEM_Staff_Splitbark.ITEM_Staff_Splitbark` (O:219001)
- Axe: `/Game/Gameplay/Character/Player/Equipment/Held/Hatchet/ITEM_Logging_Axe_Iron.ITEM_Logging_Axe_Iron` (O:224944)
- Pickaxe: `.../Pickaxe/ITEM_Pickaxe_Iron.ITEM_Pickaxe_Iron` (O:224953)

**Armour data assets** (235 `WearableEquipmentData` loaded), e.g. `/Game/Gameplay/Character/Player/Equipment/Body/ITEM_Armour_T4_Body_Iron.ITEM_Armour_T4_Body_Iron` (O:195770).
- `UWearableEquipmentData` (DOM `class UWearableEquipmentData`) has `MaleMeshData`/`FemaleMeshData` and `GetSkeletalMesh(EBodyType)`. That suggests clients build the mesh themselves from the replicated data pointer, so no client asset change is needed. MEDIUM.
- Black Knight armour exists as **player** armour mesh data: `/DowdunReach/Gameplay/Character/Player/Equipment/Body/ITEM_Armour_Body_BlackKnightMelee_MeshData_Male` and others.

**Driving it on a puppet: two options.**

1. **Replicated-state route (recommended first).** On the server:
   - Write `CurrentBodyWearable` and the other slots.
   - Spawn a held actor for the weapon, set its `HeldEquipmentData`, attach it to the puppet's mesh at `HeldRightSocketName` with `K2_AttachToComponent` (O:316), and assign `HeldEquipmentActorRight`.
   - Clients run their `OnRep_*` handlers.
   - Weapon switching is destroy-and-respawn of the held actor.
   - Confidence MEDIUM that armour shows, MEDIUM-LOW for the weapon (see the risk below).
2. **Hybrid controller route (stretch).** Spawn a connectionless `BP_PlayerController_C` purely as a host for the components, without possessing anything.
   - Call `equip:ReceiveControllerChanged(puppet, nil, fakePC)` and `performer:SetupLoadoutDelegates(puppet, nil, fakePC)`.
   - Then put items into `fakePC:GetLoadout()` with `AddItemByDataToSlot(ItemData, SlotIndex, 1, 1.0, {})`, using `ELoadoutSlot` (HeldRight=7, Body=1; CXX Dominion_enums.hpp:2193).
   - This would run the game's own equip code. LOW, because a lot of native code probably calls `GetDominionPlayerController()`, which will still return null.

**Risks.**
- The server log line `DominionPlayerEquipment ... HandleHeldBunchedRepd() : CurrentHoldable` (DISCOVERIES) and `ADominionCharacterBase.NetComponents` / `bEnableComponentsDormancy` (DOM:9667, DOM:9674) suggest Dominion replicates held items through a custom "bunched" path rather than plain UPROPERTY replication. If so, writing `HeldEquipmentActorRight` may not be enough. Armour has no such log line.
- A malformed held actor (for example a null `HeldEquipmentItem`) could crash Luis's **client**. That is recoverable (he rejoins), but warn him first.

**Simplest and safest variant: mirror Luis.**
- Read his own `HeldEquipmentActorRight`: its class, `HeldEquipmentData`, attach parent (`RootComponent:GetAttachParent()`, O:848) and `GetAttachSocketName()` (O:846).
- Reproduce exactly that on the puppet.

### A.3 Inventory components (for a puppet)

- `GetInventory()`, `GetPersonalInventory()` and `GetLoadout()` exist only on the controller (DOM:10300-10308). HIGH. The puppet has **no** inventory.
- Options:
  - (a) Keep the companion's inventory **virtual** in Lua/Python. Items it "picks up" are destroyed in the world and counted. `give` becomes `AddItemByData` on Luis's inventory (already documented). Simple and robust.
  - (b) Use the hybrid fake PC's `InventoryComponent` (LOW, as above).
  - (c) Spawn a free-standing `UInventoryComponent`. No API to do that cleanly; skip.
- Recommendation: (a). It also fits "verified state only": the count is ours, and Luis's inventory is checked with `GetNumItemsByData`.

### A.4 The action system (attacks, evades, tool use)

**How a real player attacks.** HIGH for the classes; MEDIUM for the flow.
1. Input arrives through the controller's Enhanced Input.
2. `UPlayerActionPerformer` (pawn) maps it to a `UPlayerAction`, using `CurrentlyTriggeredActions: TMap<EActionInputType, FPlayerActionInstance>` and `LHActionLoadout`/`RHActionLoadout` (DOM:29196-29214).
   - Default actions: `DefaultPrimaryAction`, `DefaultSecondaryAction`, `DefaultSpecialAction`, `DefaultEvadeAction`.
   - Per-weapon actions: `UHeldEquipmentData.PrimaryActionClass`, `SecondaryActionClass`, `SpecialActionClass`, `PrimarySprintActionClass`, `PrimaryVisceralActionClass` (DOM:23739+).
3. Melee: `UPlayerMeleeAttackAction.AttackData` (`TSubclassOf<UPlayerAttackData>`, O:64463; DOM:30168), e.g. `PA_Attack_Sword_C` (O:201947) → `BP_Player_Sword_Attack1_C` (O:201920). Combos chain through `UPlayerAttackData.NextAttackClass`.
4. The client predicts the action and sends it **inside the movement stream**.
   - `EDomMoverActionTypeIndex` (CXX Dominion_enums.hpp:1374): `0 Sprint, 1 AttackMelee, 2 AttackRanged, 3 Blocking, 4 HitReact, 6 MoveData, 7 Deflection, 8 PlayerActions`.
   - The server validates the action (`DomNetActIntIds AUTH : Action Validated/Accepted`) and acknowledges it with `UDominionMovementComponent:Client_ConfirmActionId(ActionId, ActionTypeIndex)` (DOM:20671; UHT: Client, Reliable) and `ADominionPlayerCharacter:Client_PlayerActionAcks(FPlayerActionAck)` (DOM:10118). The replicated `ConfirmedActionIdArray` is involved (DOM:9832).
   - **There is no `Server_PerformAttack`/`Server_Evade` RPC anywhere in Dominion.** The engine-level carrier is `Character:ServerMovePacked` (O:18778).
5. The server then multicasts to other clients: `UPlayerAttackComponent:Multicast_PerformAttackOnSimulatedProxies(int32 AttackId, int32 DataIndex, FVector Forward, bool bUseRootMotion, float TranslationScale, float SpeedMultiplier, FPlayerActionInstance PlayerActionInstance)` (O:63371; UHT: NetMulticast, Reliable).
   - `DataIndex` indexes `UPlayerAttackComponent.AttackDataCollection` (`TArray<TSubclassOf<UPlayerAttackData>>`, DOM:29329).
   - `Multicast_CancelAttack(AttackId)`, `Multicast_AttackHasCompleted(ActionIndex, AttackId)` and `UPlayerMeleeAttackComponent:Multicast_SendDamageCacheData(TArray<FTimedDamageInfo>)` (DOM:30186) carry the rest.

**Server-side entry points for a puppet**, best first:

| # | Call | Specifiers | What it should do | Confidence |
|---|---|---|---|---|
| 1 | `puppet.PlayerMeleeAttackComponent:BP_PerformAttack(TSubclassOf<UPlayerAttackData> DataClass, FPlayerActionInstance& PlayerActionInstance)` (O:63384) | BlueprintCallable, not authority-gated | Runs the game's own melee attack: montage, timed damage shapes (`UPlayerAttackData.TimedDamageShapes`), multicast to proxies. Under an AIController the pawn is locally controlled on the server, the same situation as a listen-server host, a code path the game supports. | MEDIUM-LOW (the damage path may depend on the mover/ack state) |
| 2 | `puppet.PlayerMeleeAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackId, DataIndex, Forward, false, 1.0, 1.0, instance)` | NetMulticast | Visual swing on all clients, with no server logic | MEDIUM for the visual |
| 3 | `puppet.PlayerAnimationManagerComponent:NetMulticast_Unreliable_PlayMontage(UAnimMontage*)` (O:63306) | NetMulticast, Unreliable | Plays any montage on every client (attack, pickup, gesture). Montage sources: `UPlayerAttackData.InPlaceAttackData` (`FAttackMontageData`), `HeldEquipmentMontage`, `UPlayerAnimationManager.DropItemMontage` | MEDIUM |
| 4 | Damage applied directly to the target (A.6) | BlueprintAuthorityOnly | The actual kill | HIGH that the API exists; MEDIUM for parameter marshalling |

`FPlayerActionInstance` (DOM:5721, size 0x60): `Data: UPlayerAction*` (the CDO of the action class), `ActionGranter: UEquipment*`, `PlayerOwner: ADominionPlayerCharacter*`, `EquipmentHand: EHandOption` (0 Left, 1 Right), `ActionInputType: EActionInputType` (0 Primary, 1 Secondary, 2 Special, 3 Evade), `DesiredActionTarget: AActor*`.

Other possibly useful calls: `ADominionPlayerCharacter:DoDash()` (DOM:10116), `CancelAllPlayerActions()` (DOM:10125) and `UPlayerAttackComponent:AttackEnded()`. Evade has no reflected trigger; `DoDash` is the nearest.

**Emotes** ("talking" body language).
- `UPlayerEmotesComponent` (DOM, UHT PlayerEmotesComponent.h):
  - `EquippedEmotes: TArray<UEmoteData*>` (O:63778)
  - `AuthoritativeEmoteIndex: int8`, ReplicatedUsing=`Rep_AuthoritativeEmoteIndex` (O:63783)
  - `PlayEmote(int8)` (O:63786; a plain UFUNCTION, callable through UE4SS)
- Emote assets: `/Game/Gameplay/Emotes/DA_Emote_Wave.DA_Emote_Wave`, `DA_Emote_Yes`, `DA_Emote_No`, `DA_Emote_Point`, `DA_Emote_Celebrate`, `DA_Emote_NoWay`.
- Puppet recipe: fill `EquippedEmotes`, then call `PlayEmote(i)`. MEDIUM.

### A.5 Can the server spawn an ADominionPlayerController without a client?

- **Mechanically yes, functionally no as a possessor.** MEDIUM-HIGH.
  - `SpawnActor(BP_PlayerController_C)` is not blocked by anything reflected.
  - On a **server-only build** (our `RSDragonwildsServer-Win64-Shipping.exe`), engine code makes `APlayerController::IsLocalController()` return false (`FPlatformProperties::IsServerOnly()`). A pawn possessed by such a controller is treated as remotely controlled. Its movement component then only simulates on incoming `ServerMove*` RPCs, which never arrive. Expect it to stand still. Engine behaviour, not verified in this build.
- Dominion's own login pipeline is client-driven:
  - `Server_SetPlayerGuid`, `Server_SetPlayerCharacterInfo` (DOM:10365-10366)
  - `Server_BeginPlayerProfileStream`, `Server_AllowPlayerCharacterToSpawn` (UHT DominionPlayerController.h:496-503)
  - The state-loaded and ready events (`OnPlayerControllerStateLoaded`, `OnPlayerControllerReady`, `IsPlayerReady()`)
  - A spawned PC would never become "ready". HIGH that these exist; MEDIUM that a spawned PC stalls.
- Engine spawn helpers are reflected if wanted:
  - `GameModeBase:RestartPlayerAtTransform` (O:22621)
  - `SpawnDefaultPawnAtTransform` (O:22613)
  - `GameplayStatics:BeginDeferredActorSpawnFromClass` / `FinishSpawningActor` (O:23449 / O:23286)

**Bot-like hooks found (complete list from targeted greps).**
- **Engine bot flags:**
  - `PlayerState:bIsABot` (O:31009)
  - `AIController:bWantsPlayerState` (O:42149). It is read in `AAIController::PostInitializeComponents`, so set it on a **deferred** spawn: `BeginDeferredActorSpawnFromClass(AIController)` → set flag → `FinishSpawningActor`.
  - The PlayerState class comes from `GameModeBase:PlayerStateClass` (O:22594). No BP PlayerState subclass is loaded, so it is likely native `DominionPlayerState`.
  - **Use:** give the puppet a PlayerState for name and nameplate (A.7). MEDIUM.
- **Spectator and free camera:** `SpectatorPawn` (O:31728), `/Game/Gameplay/Character/Player/BP_SpectatorPawn.BP_SpectatorPawn_C` (O:285114), `FreeRoamPawn` (O:56967) and `/Game/Gameplay/Cheats/BP_FreeRoamPawn.BP_FreeRoamPawn_C` (O:190818). Camera pawns only.
- **Dummies:**
  - `TargetDummyAICharacter : ADominionAICharacter` (O:69753, DOM:12484).
  - `UTrainingDummyBuildPieceComponent.TrainingDummyCharacterClass` (O:70139, DOM:36329): the buildable training dummy spawns an AI character. **This is a safe attack target for tests.**
  - `AudioTestDummy` and `FarmPlotDummy` are irrelevant.
- **No game classes named** `Bot`, `Puppet`, `Clone`, `TestPlayer`, `Fake`, `Doppel`, `Mimic` or `Avatar` (grep over `/Script/Dominion`, `/Game`, `/UmbralSands`, `/DowdunReach`, `/Script/Jagex*`). HIGH.

### A.6 Health and damage (puppet as attacker and as target)

**Puppet as attacker.** The cleanest kill path is server-side on the target's damage component. HIGH that the API exists (UHT DamageComponent.h).
1. `ev = target.<DamageComponent>:PredictDamage(EDamageClass DamageClass, TArray<FTypeDamage> TypeDamages, float ApplicationTime, AActor* Instigator, UObject* Source, FVector Location, EReactionDirectionality Directionality, float Force, int32 AttackId)` → `FDominionDamageEvent` (O:46515; BlueprintAuthorityOnly).
2. `target.<DamageComponent>:ApplyDamageFromGameplayEffect(ev, false, true)` (O:46582; BlueprintAuthorityOnly; `bMulticast=true` for hit reactions and floaties).
- Fallback: `target.<HealthComponent>:DecreaseHealth(float, FString Context)` (O:47041; BlueprintAuthorityOnly). It probably skips hit reactions, and may skip kill credit and loot.
- Supporting types:
  - Enums: `EDamageClass` (0 None, 1 Melee, 2 Magical, 3 Ranged); `EReactionDirectionality` (0 UpToDown … 4 Straight).
  - `FTypeDamage { EStatusEffectType StatusEffect; FGameplayTagContainer Types; float Amount }`.
  - `FDominionDamageEvent` fields (DOM `struct FDominionDamageEvent`): Amount, DamageClass, TypeDamagesArray, Instigator, Source, InstigatorLocation, VictimForward, VictimLocation, Directionality, Force, AttackProperties, HitReaction, AttackId, bIsFatalHit, ID, ...
- On AI the component is `ADominionAICharacter.AiDamageComponent` (`UAiDamageComponent`, also `GetAiDamageComponent()`), and health is `HealthComponent` (`UAiHealthComponent`, also `GetAiHealthComponent()`).
- **Kill credit and loot:** `ULootDropComponent:GetAllPlayersDeservingRewards(bOnlyPlayerThatInflictedDamage)` and `FLootDropContext.PlayersThatInflictedDamage` (DOM:4578, DOM:26550).
  - With `Instigator = puppet`, the puppet (a player character) may count as the damage-dealer. Loot may then be "for" a player with no controller.
  - `FItemSpawnParameters.OwnerController` and `bSpawnOnlyForController` (DOM:4111-4128) show that **per-player instanced loot exists**.
  - If loot does not appear for Luis, pass **Luis's pawn as `Instigator`**, so Luis gets the credit and the loot. MEDIUM-LOW; to test.

**Puppet as target.**
- Enemies will most likely attack the puppet: it is an `ADominionPlayerCharacter`, which implements `IGenericTeamAgentInterface`, `IAiThreatTargetInterface` and `IAISightTargetInterface` (UHT DominionPlayerCharacter.h:133). MEDIUM.
- Health: `MaxHealth` (ReplicatedUsing) and `AuthoritativeHealth` (SaveGame, ReplicatedUsing) (UHT HealthComponent.h:28-32).
- Death is the risk: respawn is `UPlayerRespawnComponent:Multicast_Respawn(FVector, FRotator)`, and the flow probably needs a DominionPlayerController.
- Protections:
  - `puppet.HealthComponent:SetIsImmortal(true, lockerObj)` (O:47010; BlueprintCallable)
  - `SetCanDie(false)` (BlueprintAuthorityOnly)
  - `SetHealth(v, ctx)`, `IncreaseHealth(v, ctx)`
  - Or `puppet.PlayerDamageComponent:SetIsInvulnerable(true, locker)` (O:46507) / `SetCanTakeDamage(false)`
  - HIGH that these exist.
- Side effects (LOW-MEDIUM): AI systems that count "players nearby" may include the puppet.
  - `Curve_AIMaxHealthPerPlayerNeaby`: enemies get tougher near more players.
  - `DominionAiFunctionLibrary:GetPlayersInRadius` / `GetClosestPlayer`, and AiDirector spawning around players.

### A.7 Appearance and name

**Appearance.**
- `UPlayerCustomizationComponent.CustomizationSaveData` (`FCharacterCustomizationSaveData`, ReplicatedUsing=`OnRep_PlayerCustomization`; O:63750; UHT :21; DOM:1826).
- Its fields are eight `FDataTableRowHandle`s: `BodyTypeDataHandle`, `FaceDataHandle`, `HairPresetDataHandle`, `FacialHairPresetDataHandle`, `HairColorPrimitiveDataHandle`, `SkinTonePrimitiveDataHandle`, `EyeColorPrimitiveDataHandle`, `EyebrowColorPrimitiveDataHandle`.
- `BodyType` (`EBodyType` 0 Male, 1 Female) is Transient and derived.
- Copy Luis's handles, then change one or two `RowName`s, so the puppet is a different-looking human. MEDIUM.

**Name.**
- Player names are resolved through `UDisplayNameComponent` (on `ADominionGameStateBase`, DOM:9764, and on `ADominionPlayerState`).
- Its replicated `OriginalCharacterNames: TArray<FDomCharacterDisplayName{ AccountGuidSaveStr, CharacterGuid, CharacterName }>` is marked SaveGame and ReplicatedUsing.
- Registration: `Server_RegisterCharacter(FDomOwnerGuid OwnerGuid, FString CharacterName)` (O:52735; Server, Reliable). On the server it runs locally.
- The nameplate is `BP_Player_Nameplate_C : UPlayerNameplateComponent` (a widget component, no reflected name field). It probably reads PlayerState → OwnerGuid → display name.
- So: puppet PlayerState (A.5) + `OwnerGuid.CharacterGuid` = a new GUID + `Server_RegisterCharacter(..., "Companion")` gives a named puppet. LOW-MEDIUM. The entry goes into the world save (SaveGame), which is fine for the throwaway world.

### A.8 Not-a-player humanoids that render like players

- `APlayerCharacterPreview : AActor` (DOM:11731, O:63533).
  - A full player body built from equipment and customization (`ApplyFullCustomization`, `UpdateOutfit`).
  - It has **no replicated properties** (UHT); it is the character-creation and inventory preview, client-side. Not usable. HIGH.
- `UMannequinSkeletalMeshComponent : UBuildingSkeletalMeshComponent` (O:61532), used by the build piece `/Game/Gameplay/BaseBuilding/Data/BuildingPieces/Furniture/Storage/BUILDPIECE_ArmourMannequin` (O:236365).
  - An armour stand: a static humanoid that displays armour. It replicates through the building system but cannot walk. HIGH.
- `UProxyPlayerAnimationManager` (O:65654): animation proxying, not a body.
- The puppet itself (`BP_PlayerCharacter_C` + AIController) is the best answer here.

---

## B. Route 2: a humanoid AI on our side

### B.1 Humanoid AI classes

**Runtime-verified paths** (`AISpawnPoint.AIClass` values and live actors in LOG `body_probe_director` / `body_probe_class`; HIGH):

| Class | Notes |
|---|---|
| `/DowdunReach/Gameplay/AI/BlackKnightFaction/1HMeleeBlackKnight/BP_AI_1HMeleeBlackKnight_Character.BP_AI_1HMeleeBlackKnight_Character_C` | human knight, one-handed melee. **Best candidate.** |
| `/DowdunReach/Gameplay/AI/BlackKnightFaction/2HMeleeBlackKnight/BP_AI_Melee2HBlackKnight_Character.BP_AI_Melee2HBlackKnight_Character_C` | two-handed melee |
| `/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/BP_AI_MeleeGoblin_Character.BP_AI_MeleeGoblin_Character_C` | goblin melee ("Grunt") |
| `/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/RuntGoblinVariant/BP_AI_RuntGoblin_Character.BP_AI_RuntGoblin_Character_C` | small goblin |
| `/DowdunReach/Gameplay/AI/Wildlife/Hellhound/BP_AI_HellHound_Character.BP_AI_HellHound_Character_C` | not humanoid (the Houndmaster's dog) |

**Known only from journal entries, class paths unknown.** Journal entries are `UJournalEntryWorldData` at `/Game/UI/JournalData/Entries/World/Factions/JOURNAL_World_Factions_*` (O:243467 and nearby); each holds an `UnlockCondition.AIData` soft class pointer to the AI's data asset (DOM:4190-4199), which is a cheap way to learn more data classes at runtime.
- Black Knight: 1H, 2H, Melee, Ranged, Houndmaster, SgtBlister, Titan.
- Goblin: Grunt, Bruiser, Runt, Shooter (ranged).
- Zamorak (human cultists): Acolyte, Mage, DemonMaster, RatMaster.
- Fellhollow undead: Skeleton Archer, Hoplite, Marauder, Necromancer, Warrior (and Rotsworn variants), Zombie, Zogre.
- Garou (werewolves): Berserker, Druid, Ranger, Thane, King.
- Vault Guardian: Melee/Ranged.
- Path guesses from the observed pattern (UNVERIFIED): `/DowdunReach/Gameplay/AI/BlackKnightFaction/<Variant>BlackKnight/BP_AI_<Variant>BlackKnight_Character...` and `/Game/Gameplay/AI/GoblinFaction/<Variant>Goblin/...`.

AI difficulty categories: `/Game/Gameplay/DifficultySettings/AI/CategoryScaling/{Beast, Boss, Construct, Critter, Garou, Goblin, Kalphite, Kothaar, MiniBoss, Skeleton, Undead, Zamorak}`. Humanoid art loaded at idle: only `M_MED_Goblin_Melee_01`, `M_MED_Goblin_Ranged_01` and `M_MED_Goblin_Runt_01` (`/Game/Art/Skeleton/NPC/Humanoid/...`), pulled in by a key-art cinematic (O:270726).

**Controllers.**
- Every AI has a BP subclass of `ADominionAIController` (`dump-body.md` section 1).
- The friend reuses the soldier's controller (`BP_AI_KalphiteSoldier_Controller_C`, LOG). Controllers are therefore per faction or per body type, not per allegiance. HIGH.

### B.2 Weapons and attacks on AI (and whether they switch)

- **AI weapons are not equipment.** No AI class has a `HeldEquipmentActor` or loadout. HIGH.
  - Attacks are defined by the **AI data asset**: `UAIDataAsset` (DOM:13748), referenced by `ADominionAICharacter.AIDataClass` (soft class pointer, DOM:9474).
  - Fields: `AiCombatStyle` (`AI_COMBAT_STYLE`: 0 Melee, 1 Ranged; O:46595), `CombatAttacksTable` (O:46632), `CombatRangedAttacksTable` (O:46633), `CombatActionsTable`, `RangedCombatConfig`, `PreferredDistanceFromTarget`, `Archetype` (`AI_ARCHETYPE`: 0 Aggressive, 1 Defensive, 2 Passive, 3 Bird, 4 NeutralUntilAttacked).
  - Rows point to `UAiAttackData` (montage, damage, combos; DOM `class UAiAttackData`) and `UAiRangedAttackData` (projectile class, miss chance, ...).
- Components:
  - `ADominionAICharacter.AiAttackComponent` (`UAiAttackComponent`, DOM:14608)
  - `AiRangedAttackComponent` (`UAiRangedAttackComponent`, DOM:14839)
  - `AttackOpportunityComponent`
  - Multicasts: `UAiAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackClassId, AttackId, bFromCombo)`.
- **Mixed melee and ranged on one body exists.** `BP_AI_KalphiteSoldier_Character_C` carries both `BP_GiantRat_AiAttackComponent` and `BP_RangedBeast_RangedAttackComponent` (CXX BP_AI_KalphiteSoldier_Character.hpp). HIGH.
- **Weapon visuals are part of the AI's own meshes.** Weapons can be dropped on death: `UAiDeathComponent.MeshesToDropOnDeath`; `DominionAiFunctionLibrary:DropMeshComponent(Actor, Component, ...)`. MEDIUM.
- **Runtime weapon switching is not supported natively.** Variants are separate classes (1H vs 2H Black Knight, Grunt vs Shooter goblin). The combat style lives on the data asset, which all instances of a class share. MEDIUM-HIGH.
  - Switching would mean swapping bodies, or attaching a second static mesh, which is cosmetic only. A Route 2 companion is effectively "one weapon kit per class".

### B.3 Faction, team and hostility

- **Attitude is computed natively.** Neither `GetGenericTeamId` nor any team ID property is reflected. HIGH.
- Reflected queries (UHT DominionAiFunctionLibrary.h; CDO `/Script/Dominion.Default__DominionAiFunctionLibrary`, O:173257):
  - `GetAttitude(const ADominionAICharacter* AI, const AActor* Target)` → `ETeamAttitude` (0 Friendly, 1 Neutral, 2 Hostile) (O:71716)
  - `IsTargetFriendly(ADominionAIController* FromController, AActor* Target, bool bNeutralsAreValid)` (O:71542)
  - `IsPlayerOrPlayerAgent(const FJgxActorFacadeHandle&)` (O:71547): the "player agent" concept
  - `GetAiInRangeAccordingToAttitude(Querier, Origin, Range, ETeamAttitude, bExclude)`
  - `GetElementalableAIWithinRange(..., FGameplayTag FactionFilterTag)`: **factions are gameplay tags**, probably in `UAIDataAsset.GameplayTags`
  - `DrawAgroOnBehalfOfPlayer(ADominionPlayerCharacter* Player, AActor* ActorToDrawAgro, float Range)` (O:71750)
  - `AnyInjuredAiInRange(..., bOnlyFriendlyAI)`
- **What decides who an AI attacks.** MEDIUM.
  - The threat system on the controller: `UAiThreatSystem` (DOM:15008), with `OverrideTarget` (`FJgxActorFacadeHandle`, O:47646), `DamageInstigators`, a perception component, and `FAIThreatSystemConfig.TargetSelectorStrategy` (DOM:320).
  - The character's own `CurrentTarget` (ReplicatedUsing, O:53391) and `SpecifiedTargetOverride` (O:53442).
- **Ways to steer it:**
  - `ADominionAICharacter:SetSpecifiedTargetOverride(const FJgxActorFacadeHandle&)` (O:53453; BlueprintAuthorityOnly) and `GetSpecifiedTargetOverride()`.
  - The handle comes from `/Script/JagexEngine.Default__ActorFacadeBlueprintLibrary:ToFacade(AActor*)` (O:41732; CDO O:167146). `FJgxActorFacadeHandle` is an opaque 8-byte struct (CXX JagexEngine.hpp:4), so pass the returned value straight through.
  - `SetAttacksDisabled(bool, Locker)` and `SetOverrideCanEngageForAI(AI, bool)` (UHT DominionAiFunctionLibrary.h:66).
  - `SetOverrideMemoryDurationForAI(AI, float)` and `SetAllowAlertnessStateChange(AI, bool)`.

### B.4 How the Kalphite friend is made friendly (the template)

- **Facts.**
  - Spawned by `FollowerComponent:ToggleFollower(DA_Kalphite_Friend)`.
  - The live actor `BP_AI_KalphiteFriend_Character_C` reported `is_confused=true`, `is_follower=true`, `PowerLevel=7`, `bSkipSpudStore=true` and controller `BP_AI_KalphiteSoldier_Controller_C` (LOG 12:42 UTC). HIGH.
  - `UFollowerComponent.Handle` (`FDominionGameplayEffectHandle`, UHT FollowerComponent.h:28) and `UFollowerDataAsset.EffectToApplyDuringSummon` (`dump-body.md` section 6) show that the follower system **applies a gameplay effect to the summon**.
  - `UConfuseGameplayEffectData` (DOM:17564) has `bShouldFollowConfuser`, `bTakingDamageCanRemoveConfuse`, `bShouldAgroPulse` and `AgroPulseRange`. The Confuse spell's effect is `GE_Confuse_C` (CXX GE_Confuse.hpp).
- **Inference.** MEDIUM-HIGH.
  - The friend is a Kalphite Soldier body with a permanent confuse-and-follow effect, plus the "follower" flag.
  - Confused AI treat the confuser's enemies as theirs: they take extra damage against AI (`DamageMultiplerVsAIWhenConfused`) and pull aggro from nearby enemies onto themselves (`bShouldAgroPulse`).
  - Whether the friend *actively seeks* enemies or only retaliates is not in the dump. Measure it with `GetAttitude(friend, wolf)` and by watching.
- **Applying the template to a humanoid**, in order of nativeness:
  1. `bk:Confuse(luis_pawn, true)` on a spawned or wild Black Knight.
     - Check `bk:CanBeConfusedBy(luis_pawn)` first. Results (`ECanConfuseResult`): 0 Immune, 1 PlayerPowerLevelTooLow, 2 RequiresPerk_GreaterConfuse, 5 CanConfuse.
     - The data asset's `ConfuseRequirements` (`EAIConfuseRequirements`: 0 Immune, 1 RequiresGreaterConfusePerk, 2 CanConfuse; O:46645) and `PlayerPowerLevelGapRequiredToConfuse` gate it. If it is gated, spawn with a low power level (`AsyncDomSpawnAIAtLocation(..., PowerLevel=1)`).
  2. **A follower data asset pointing at the Black Knight.** Either write `DA_Kalphite_Friend.FollowerClass` (soft class pointer, O:56905) to the Black Knight class at runtime, or `StaticConstructObject` a new `UFollowerDataAsset`. Then call `ToggleFollower`. This reproduces exactly what the game does for the Kalphite. The data asset lives only on the server and the client only sees a replicated Black Knight. LOW-MEDIUM; soft-pointer writes from UE4SS are untested.
  3. Steer the fight with `SetSpecifiedTargetOverride(ToFacade(enemy))`, and keep it close with `SetOverrideTetherRangeForAI(bk, 1e6)`.
- **Route 2 limits:**
  - It looks like a Black Knight, not like Luis's friends.
  - One weapon kit per class.
  - No inventory and no pickup: loot would be virtual, as in A.3.
  - The follow stalls at range (seen with the Kalphite) and needs re-applying on rejoin (already handled by `companion.lua`).

---

## C. Loot and weapons for an AI body

**How loot drops work.** HIGH for the structures; MEDIUM for the flow.
- **Creatures:** `ULootDropComponent` (DOM:26550) has `EnemyTableRowHandle` → `FLootDropEnemyTableRow.TablesByPowerLevel` → `FLootDropTableRow { Conditions, DropChance, Resources, Recipes }` (DOM:4585-4605). Also `AdditionalLootDrops: TArray<FAdditionalLoot>`, `DefaultResourceClass`, launch parameters, and `GetAllPlayersDeservingRewards(bOnlyPlayerThatInflictedDamage)`.
- **World objects:** `UItemDropComponent` (DOM:25382) has `ItemsToDrop: TArray<FItemDropData>` and the BlueprintCallable `DropItems(Instigator)` (O:59599), `DropItemsFromConfig`, `DropItemsOfClass`, `ReplaceItemsToDrop` and `AddItemsToDrop`.
  - `FItemDropData` (DOM:4094): `ItemDataClass` (soft), `MinToDrop`, `MaxToDrop`, `MaximumGrouping`, `ProbabilityOfDrop`, ...
- **Spawning one item:** `UItemHelperLibrary:SpawnAndLaunchItem(WorldContext, FItemSpawnParameters)` (O:59630; CDO O:172727). `FItemSpawnParameters` (DOM:4111) fields:
  - `ItemClass` (TSubclassOf<AWorldItem>), `bCreateItem`, `bMagnetize`, `SpawnedItemData`, `CopiedItem`, `Count`
  - `Transform`, `LaunchDirection`, `LaunchSpeed`, `LaunchAngleVariance`, `bSkipFloorSafetyCheck`
  - `OwnerController`, `bSpawnOnlyForController`, `PlayerControllerThatDroppedItem`, `bAddToWorldItemRuntimeCache`, `bMagnetizeToInstigatorOnSpawn`
- **World item classes:**
  - `AWorldItem` (DOM:12734): `ItemData`, `MagneticComponentGrantItem`, `ItemMesh`, owner/dropper GUIDs.
  - `ARuntimeSpawnedWorldItem : AWorldItem` (DOM:12114).
  - BP variants: `/Game/Gameplay/WorldItems/BP_RuntimeSpawnedWorldItem`, `..._NoDelayForMagnet`, `..._NoExpiry`, `..._ProcessingStation`.

**Can a non-player pick items up?** HIGH for the signatures; MEDIUM for the outcome.
- Every pickup path takes an `ADominionPlayerCharacter*`:
  - `ARuntimeSpawnedWorldItem:HandleInteraction(Interactee)` (O:66888)
  - `BaseInteractableResource:OnInteraction(PlayerCharacter)`
  - `MagneticComponent:BP_MagnetizeToPlayer(Player, bIgnoreMinTimeBeforeMoving)` (O:60878)
- They then grant into **that player's controller inventory**:
  - An AI body (Route 2) cannot pick up.
  - The puppet (Route 1) *is* an `ADominionPlayerCharacter`, but has no controller inventory, so `HandleInteraction(puppet)` will most likely fail or no-op. Untested; a crash is possible.
- **Practical "pickup" for either route:**
  1. Walk to the item.
  2. Play a pickup or drop montage.
  3. Either `item.MagneticComponentGrantItem:BP_MagnetizeToPlayer(luis_pawn, true)`, so the loot flies to Luis (the native magnet animation, granted into Luis's real inventory), **or** `K2_DestroyActor()` plus a virtual count, with `AddItemByData` to Luis later for `give`.
  - Verify with `GetNumItemsByData` on Luis.
- Find loot near a kill with `FindAllOf("WorldItem")` within about 5 m of the corpse, recording `ItemData:GetFullName()` and the stack count (`GetStackSize()`).

**The AI's weapon** (from B.2):
- Defined by the data asset's attack tables and baked meshes, not by equipment.
- Cannot be swapped at runtime natively. Swapping the whole data asset (`AIDataClass` is a soft class pointer, and `LoadedData` is the loaded instance) on a live AI is LOW confidence and likely unsafe.
- Weapon switching is a Route 1 feature (held actor swap), not a Route 2 one.

---

## D. Speech: a named line in chat from the server

Structs (CXX JagexChatBackend.hpp, full listing; HIGH):

```
FChatMessageData      (0x88) { FChatPlayerSenderData SenderData @0x00; FString MessageBody @0x78 }
FChatPlayerSenderData (0x78) { FUniqueNetIdRepl PrimaryNetId @0x00; FUniqueNetIdRepl SecondaryNetId @0x30;
                               FGuid CharacterGuid @0x60; int32 PlayerId @0x70; FColor Color @0x74 }
FChatPlayerFilterData (0x40) { FUniqueNetIdRepl SenderId; TArray<FUniqueNetIdRepl> ReceiverIds }
FChatPlayerEventData  (0x80) { FChatPlayerSenderData SenderData; FGameplayTag Tag }
FGuid  { int32 A, B, C, D }      FColor { uint8 B, G, R, A }   (UE4SS: set by name: R, G, B, A)
```

**Identity structs used by names** (DOM):
- `FDomOwnerGuid { FDomCharacterGuid CharacterGuid; FDomOnlineCapableAccountGuid AccountGuid }`
- `FDomCharacterGuid { FGuid InnerGuid }`
- `FDomOnlineCapableAccountGuid { FUniqueNetIdRepl NetIdPrimary, NetIdSecondary }`
- `FDomCharacterDisplayName { AccountGuidSaveStr; CharacterGuid; CharacterName }`

**Options, ranked:**

1. **`Client_ReceiveChatMessage(FChatMessageData)`** on each `BP_PlayerController_C.PlayerChat` (O:45127; UHT: BlueprintCallable, Client, Reliable).
   - Called on the server, it is sent to that controller's owning client. There is no validation step.
   - The client UI (`UChatWidget:OnChatMessageReceived(FChatMessageData)`, DOM:17151) resolves the sender for display. The dump does not show how.
   - Likely keys, in order: `CharacterGuid` → `UDisplayNameComponent` (on the GameState) name; `PlayerId` → PlayerState; `PrimaryNetId`.
   - **Plan:** build `SenderData` with a fresh `CharacterGuid`, a `PlayerId` that no real player uses (Luis's was 256), a distinctive `Color`, and empty NetIds. Register a name for that GUID first with `GameState.DisplayNameComponent:Server_RegisterCharacter({CharacterGuid={InnerGuid=g}}, "Companion")` (O:52735; on the server the Server RPC runs locally, and `OriginalCharacterNames` replicates to clients).
   - MEDIUM that the line appears; LOW-MEDIUM that the name shows.
2. **Echo variant.** In the `Server_SendChatMessage` hook (already live), keep the last `SenderData` from Luis: `CharacterGuid`, `PlayerId` and `Color`. NetIds cannot be copied reliably from Lua.
   - Sending a line with Luis's own `CharacterGuid` but a prefixed body (`"[Companion] ..."`) **certainly** renders, but under Luis's name.
   - A useful fallback that works for sure if option 1 shows a blank name.
3. **`Server_SendChatMessage`** called server-side on Luis's `PlayerChat` (Server, Reliable, **WithValidation**): uses the game's own fan-out, but `_Validate` may reject a mismatched sender. MEDIUM-LOW.
4. **Non-chat channels:**
   - `DominionPlayerController:Client_DisplayTextNotification(FGameplayTag, FText)` (O:73027): a toast.
   - `UPingComponent:Client_NotifyPing(FVector Location, FDomCharacterGuid RequestingPlayerGuid)` (DOM:29135, on the controller): the companion "pings" a spot on Luis's map or HUD, for example "ore here".
   - Puppet emotes (A.4).

---

## E. Ranked experiments for the next in-game session

All are UE4SS Lua for one new module (suggested `mod/scripts/puppet_gear.lua`), run with `debug_run {module, args={action=...}}`. Reuse `try`, `valid`, `fullname`, `vec` and `split_pawns` from `mod/scripts/puppet_test.lua`.

All snippets are **UNTESTED**. Wrap every call in `pcall`, log a trace line before each risky call, and tell Luis before E2 and E3 that his client might crash.

Shared lookups:

```lua
local function cdo(p) return StaticFindObject(p) end
local function puppet_and_luis() local pl, pu = split_pawns(); return pu[1], pl[1] end
local LIB_FACADE = "/Script/JagexEngine.Default__ActorFacadeBlueprintLibrary"
local LIB_AI     = "/Script/Dominion.Default__DominionAiFunctionLibrary"
```

### E1. Dress the puppet: appearance and armour (lowest risk, highest value)

```lua
local p, luis = puppet_and_luis()
-- 1) appearance: copy Luis's row handles field by field
local src, dst = luis.PlayerCustomizationComponent.CustomizationSaveData, p.PlayerCustomizationComponent.CustomizationSaveData
for _, k in ipairs({"BodyTypeDataHandle","FaceDataHandle","HairPresetDataHandle","FacialHairPresetDataHandle",
                    "HairColorPrimitiveDataHandle","SkinTonePrimitiveDataHandle","EyeColorPrimitiveDataHandle","EyebrowColorPrimitiveDataHandle"}) do
  dst[k].DataTable = src[k].DataTable; dst[k].RowName = src[k].RowName
end
p.PlayerCustomizationComponent:OnRep_PlayerCustomization()
-- 2) armour: write the replicated wearable slots
local eq = p.PlayerEquipmentComponent
eq.CurrentBodyWearable = StaticFindObject("/Game/Gameplay/Character/Player/Equipment/Body/ITEM_Armour_T4_Body_Iron.ITEM_Armour_T4_Body_Iron")
eq:OnRep_CurrentBodyWearable(nil)
p:ForceNetUpdate()
log.event("e1", { body = fullname(eq.CurrentBodyWearable), luis_body = fullname(luis.PlayerEquipmentComponent.CurrentBodyWearable) })
```

- Also log Luis's own `CurrentHead/Body/Legs/CapeWearable`, for reference and as a source to copy.
- **Ask Luis:** "Does the second character now look like a person with your face and hair, wearing iron body armour? Yes/No, and anything odd."
- **Pass:** both are yes. If the customization copy does nothing, `dst` was a copy: assign the whole struct (`p.PlayerCustomizationComponent.CustomizationSaveData = src`) and retry.

### E2. Arm the puppet and switch weapons (held actor via replicated state)

```lua
local p, luis = puppet_and_luis()
-- First, learn from Luis's real held actor (read-only):
local lh = luis.PlayerEquipmentComponent:GetHeldEquipmentActorRight()
local lroot = valid(lh) and lh.RootComponent
log.event("e2.mirror", { cls = valid(lh) and fullname(lh:GetClass()), data = valid(lh) and fullname(lh.HeldEquipmentData),
  item = valid(lh) and fullname(lh.HeldEquipmentItem), id = valid(lh) and lh.HeldEquipmentActorID,
  parent = valid(lroot) and fullname(lroot:GetAttachParent()), socket = valid(lroot) and lroot:GetAttachSocketName():ToString(),
  sock_cfg = luis.PlayerEquipmentComponent.HeldRightSocketName:ToString() })
-- Then build one for the puppet:
local data = StaticFindObject("/DowdunReach/Gameplay/Character/Player/Equipment/Held/Sword/ITEM_Sword_Mithril.ITEM_Sword_Mithril")
local cls  = valid(lh) and lh:GetClass() or StaticFindObject("/Game/Gameplay/Character/Player/Equipment/Held/BP_HeldEquipmentBase.BP_HeldEquipmentBase_C")
local w = p:GetWorld():SpawnActor(cls, vec(p), {Pitch=0,Yaw=0,Roll=0})
w.HeldEquipmentData = data
w:K2_AttachToComponent(p.Mesh, p.PlayerEquipmentComponent.HeldRightSocketName, 2, 2, 1, false)   -- SnapToTarget, SnapToTarget, KeepWorld
p.PlayerEquipmentComponent.HeldEquipmentActorRight = w
p.PlayerEquipmentComponent:OnRep_HeldEquipmentActorRight(nil)
p:ForceNetUpdate(); w:ForceNetUpdate()
```

- If Luis's held actor is attached to a mesh other than `p.Mesh`, use the same-named component on the puppet.
- **Switch:** destroy `w` (`K2_DestroyActor`), set the slot to nil, then repeat with `ITEM_Shortbow_Oak` or `ITEM_Logging_Axe_Iron`.
- **Ask Luis:** "Is the second character holding a sword in its right hand, and does it move with the hand when it walks? Yes/No. Now (after switch): is it holding a bow?"
- **Pass:** the sword is visible and moves with the hand.
- **If it is invisible:** Dominion's custom held-item replication (`HandleHeldBunchedRepd`) is the cause. Fall back to the hybrid fake-PC loadout path in A.2 (option 2) as a separate experiment.

### E3. Puppet melee swing and a real kill (target: training dummy, then a goblin)

```lua
local p = puppet_and_luis()
local target = --[[ nearest TargetDummyAICharacter, else nearest hostile DominionAICharacter within 20 m ]]
p.Controller:MoveToActor(target, 150.0, true, true, true, nil, true)   -- O:42187; then face the target
local atk = StaticFindObject("/Game/Gameplay/Character/Player/Attacks/Sword/BP_Player_Sword_Attack1.BP_Player_Sword_Attack1_C")
local act = StaticFindObject("/Game/Gameplay/Character/Player/Attacks/Sword/PA_Attack_Sword.Default__PA_Attack_Sword_C")
local hp0 = target.HealthComponent:GetAuthoritativeHealth()
-- (a) the game's own attack
local ok, err = pcall(function() p.PlayerMeleeAttackComponent:BP_PerformAttack(atk,
  { Data = act, PlayerOwner = p, EquipmentHand = 1, ActionInputType = 0, DesiredActionTarget = target }) end)
-- 1.5 s later: hp1 = target.HealthComponent:GetAuthoritativeHealth()
-- (b) if hp1 == hp0: damage directly, keeping the swing for visuals
local dc = target.AiDamageComponent or target:GetAiDamageComponent()
local ev = dc:PredictDamage(1, { { StatusEffect = 0, Types = {}, Amount = 25.0 } }, 0.0, p, p,
                            target:K2_GetActorLocation(), 4, 1.0, 0)
dc:ApplyDamageFromGameplayEffect(ev, false, true)
```

- Log `ok`/`err` and the health before and after (a) and (b).
- Visual fallback when (a) errors: `p.PlayerAnimationManagerComponent:NetMulticast_Unreliable_PlayMontage(<montage>)`. Take the montage from `atk`'s CDO (`InPlaceAttackData`) or `HeldEquipmentMontage`, and log what those fields hold.
- **Ask Luis:** "Did the second character swing its sword at the dummy/goblin, and did the target flinch or lose health? Yes/No. When the goblin died, did loot appear?"
- **Pass:**
  - Health drops.
  - A goblin dies after N hits.
  - The loot question is answered. If no loot appeared, repeat (b) with `Instigator = luis_pawn`, to test the kill-credit question in A.6.

### E4. Puppet survives combat

- Call `p.HealthComponent:SetIsImmortal(true, p)` and `SetCanDie(false)`.
- Read `DominionAiFunctionLibrary:GetAttitude(goblin, p)` (expect 2, Hostile) and `GetAttitude(goblin, luis)`.
- Watch `p.HealthComponent:GetAuthoritativeHealth()` while a goblin is nearby.
- **Pass:** goblins attack the puppet, and its health floors at a value above 0 or does not drop.

### E5. Named chat line

1. In `hooks.lua`, store the last `SenderData` from `Server_SendChatMessage`: `CharacterGuid.A..D`, `PlayerId` and `Color`. This needs a restart, or an equivalent `debug_run` read of the last logged values.
2. `debug_run` steps:

```lua
local gs = FindFirstOf("DominionGameStateBase")
local g = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 }
gs.DisplayNameComponent:Server_RegisterCharacter({ CharacterGuid = { InnerGuid = g } }, "Companion")
for _, pc in ipairs(FindAllOf("BP_PlayerController_C") or {}) do
  pc.PlayerChat:Client_ReceiveChatMessage({ SenderData = { CharacterGuid = g, PlayerId = 9001,
     Color = { R = 80, G = 200, B = 255, A = 255 } }, MessageBody = "Hello! I'm right behind you." })
end
```

- Then try the variants in order:
  - (b) same, without the registration
  - (c) Luis's `CharacterGuid` + `PlayerId`, body prefixed `"[Companion] "`
  - (d) `Server_SendChatMessage` on Luis's `PlayerChat` with the same data and an empty filter
- Log `IsCharacterNameReady(owner)` and `GetCharacterDisplayName(owner, "")` after registering.
- **Ask Luis** after each variant: "Did a chat line appear? What name was shown in front of it?"

### E6. Route 2 in parallel: a friendly Black Knight

1. Spawn `BP_AI_1HMeleeBlackKnight_Character_C`, 6 m from Luis. Use T4 (`AsyncDomSpawnAIAtLocation`, PowerLevel 1) or T5 (`SpawnActor` + `SpawnDefaultController`) from `dump-body.md`; the class must first be loaded with `LoadAsset(path)`, since it is DowdunReach content.
2. Log `CanBeConfusedBy(luis)`, then call `Confuse(luis, true)` and `SetOverrideTetherRangeForAI(bk, 1e6)`.
3. Log `IsConfused`, `IsFollower`, `GetAttitude(bk, luis)` and `GetAttitude(bk, goblin)`.
4. Bring it near goblins and call `bk:SetSpecifiedTargetOverride(cdo(LIB_FACADE):ToFacade(goblin))`.

- **Ask Luis:** "Did a Black Knight appear and follow you without attacking you? When we pointed it at the goblin, did it fight it?"
- Then try B.4 option 2: a follower data asset pointing at the Black Knight class.

### E7. Loot hand-over (works with either route)

1. After a kill, `FindAllOf("WorldItem")` within 5 m of the corpse. Log the class, `ItemData` and `GetStackSize()`.
2. Walk the puppet to each item (`MoveToActor`).
3. Call `item.MagneticComponentGrantItem:BP_MagnetizeToPlayer(luis, true)`.
4. Check `luis.Controller:GetInventory():GetNumItemsByData(item.ItemData)` before and after.

- **Ask Luis:** "Did the dropped items fly to you after the companion walked over to them?"

### E8. Puppet identity (stretch)

1. Spawn the AIController deferred: `GameplayStatics:BeginDeferredActorSpawnFromClass(world, AIControllerClass, xform, 1, nil, 0)` → `bWantsPlayerState = true` → `FinishSpawningActor`.
2. Possess the puppet. Read `ctrl.PlayerState`, set `bIsABot = true`, and set `OwnerGuid.CharacterGuid.InnerGuid` to the E5 GUID.

- **Ask Luis:** "Is there a name above the second character's head now?" Also check that the server's player count and sleeping logic are unaffected.

**Top 3 for the next session:** E1 + E2 (dress and arm the puppet, the same session step), then E3 (swing and kill), then E5 (named chat line). E6 is the parallel fallback if E2 or E3 shows that the puppet's equipment or attacks cannot work without a controller.
