# Dump analysis: chat, item pickup, inventory, teleport, gathering (2026-10-25)

Source: UE4SS reflection dump of the Dragonwilds dedicated server, UE 5.6, **build 26161880**,
at `C:\gameserver\dumps\26161880\`. Abbreviations used below:

- `OD:<line>` = `UE4SS_ObjectDump.txt` line (the authoritative "this path exists" check).
- `DOM:<line>` = `CXXHeaderDump\Dominion.hpp` line.
- `CHAT:<line>` = `CXXHeaderDump\JagexChatBackend.hpp` line.
- `UHT` = `UHTHeaderDump\<Module>\Public\<Class>.h` (gives the UFUNCTION specifiers: Server/Client/NetMulticast, Reliable, BlueprintAuthorityOnly, return types).

Everything here is **read from the dump only**. Nothing has been hooked or called yet, so every
"behaviour" claim is a hypothesis until the Phase 2/3 hooks confirm it.

## 0. How UE4SS hooks will behave (read first) [UNVERIFIED]

`RegisterHook` on a native UFunction fires when the function runs through the reflection path:
RPCs arriving from a client, Blueprint calls, and dynamic-delegate broadcasts (`AddDynamic`
bindings). A C++-to-C++ direct call does **not** go through it. That shapes the choices:

- `Server_*` RPCs (client → server) fire on the server: **best hooks**.
- `Multicast_*` / `NetMulticast_*` also run locally on the server: good for observing.
- `Client_*` RPCs called on the server are sent to the client and do not run locally, so hooks on
  them will most likely **not** fire on a dedicated server. They are listed for calling, not hooking.
- Plain native helpers such as `InventoryComponent:AddItemByData` only fire if something calls
  them through reflection (a Blueprint). They may stay silent even when items are added.
- Functions such as `OnInteraction(Player)` or `OnHealthChanged(...)` that are `UFUNCTION()`s with
  delegate-shaped signatures are almost certainly bound with `AddDynamic`. They fire per event.

## 1. Key classes (identity)

| Role | Class (reflected path) | Ref |
|---|---|---|
| Player character (native) | `/Script/Dominion.DominionPlayerCharacter` (`ADominionPlayerCharacter : ADominionCharacterBase : ACharacter`) | OD:72153, DOM:9779 |
| Player character (BP, spawned) | `/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C` | OD:217969 |
| PlayerController (native) | `/Script/Dominion.DominionPlayerController` (`: ADominionPlayerControllerBase : APlayerController`) | OD:72725, DOM:10139 |
| PlayerController (BP) | `/Game/Gameplay/Character/Player/BP_PlayerController.BP_PlayerController_C` | OD:219229 |
| PlayerState | `/Script/Dominion.DominionPlayerState` (OwnerGuid, PlayerColor, PlatformData, DisplayNameComponent) | OD:54241, DOM:10401 |
| GameMode / GameState (BP) | `/Game/Gameplay/GameMode/BP_GameMode.BP_GameMode_C` (`: ADominionGameMode`), `BP_GameState_C` | OD:285131, OD:285121, DOM:9730 |
| AI character (Phase 4 option b) | `/Script/Dominion.DominionAICharacter`, spawn helper `UAsyncAction_DomSpawnAI::AsyncDomSpawnAIAtLocation(WorldContext, PlayerInstigator, NavMeshOriginActor, Origin, Rotation, TSoftClassPtr<ADominionAICharacter>, PowerLevel)` | DOM:9469, DOM:15603 |

Most gameplay components hang off the **PlayerController**, not the pawn:
`InventoryController`, `InventoryComponent`, `PersonalInventoryComponent`, `LoadoutComponent`,
`PlayerChatComponent`, `ProgressComponent`, `LodestoneTeleportationComponent`, `BuildPlacementComponent`
and others (DOM:10139-10240). The pawn holds `InteractionManager` (`UPlayerInteractionManager`,
DOM:9902), `HealthComponent` (`UPlayerHealthComponent`), `PlayerDamageComponent`, `ItemMagnet`, the
attack components, and a `FollowerComponent` (`UFollowerComponent`, DOM:22965: `ToggleFollower(UFollowerDataAsset*)`,
which is worth a look for Phase 4).

## 2. Text chat

Chat lives in its own module, **`JagexChatBackend`** (not Dominion). The whole class is in
`JagexChatBackend.hpp` (70 lines).

### 2.1 Component

`/Script/JagexChatBackend.PlayerChatComponent` (`UPlayerChatComponent : UActorComponent`), OD:45112, CHAT:51.
One per PlayerController: `ADominionPlayerController::PlayerChatComponent` (DOM:10233), with the getter
`DominionPlayerController:GetPlayerChatComponent()` (UHT: BlueprintPure, returns `UPlayerChatComponent*`).
The BP controller also has `PlayerChat` (`BP_PlayerController.hpp:11`).

Delegates (multicast, BlueprintAssignable): `OnChatMessageReceived(FChatMessageData)`,
`OnChatPlayerEventReceived(FChatPlayerEventData)`, `OnSystemMessage(FGameplayTag)`,
`OnErrorMessage(FText)`. Property `bIsChatEnabled` (bool, 0x100).

### 2.2 Structs (CHAT:4-33)

```
FChatMessageData      { FChatPlayerSenderData SenderData; FString MessageBody; }          // 0x88
FChatPlayerSenderData { FUniqueNetIdRepl PrimaryNetId; FUniqueNetIdRepl SecondaryNetId;
                        FGuid CharacterGuid; int32 PlayerId; FColor Color; }               // 0x78
FChatPlayerFilterData { FUniqueNetIdRepl SenderId; TArray<FUniqueNetIdRepl> ReceiverIds; } // 0x40
FChatPlayerEventData  { FChatPlayerSenderData SenderData; FGameplayTag Tag; }              // 0x80
```

### 2.3 Functions

| Function | Params | Specifiers (UHT) | Ref | Use |
|---|---|---|---|---|
| `/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage` | `const FChatMessageData& ChatMessageData, const FChatPlayerFilterData& ChatPlayerFilterData` | BlueprintCallable, **Server, Reliable, WithValidation** | OD:45120, CHAT:64 | **Chat receive hook.** The client calls this when Luis presses Enter. Message text is `ChatMessageData.MessageBody`. |
| `/Script/JagexChatBackend.PlayerChatComponent:Server_SendPlayerEvent` | `const FChatPlayerEventData& ChatPlayerEventData` | Server RPC | OD:45118, CHAT:63 | Player "event" lines (tag-based; probably join/leave/death). Low value for commands, cheap to hook. |
| `/Script/JagexChatBackend.PlayerChatComponent:Client_ReceiveChatMessage` | `const FChatMessageData& ChatMessageData` | BlueprintCallable, **Client, Reliable** | OD:45127, CHAT:67 | Server → each client delivery. **Candidate for "say"** (see 2.4). Hooking it on the server probably will not fire. |
| `/Script/JagexChatBackend.PlayerChatComponent:Client_ReceiveSystemMessage` | `const FGameplayTag& Tag` | Client, Reliable | OD:45123, CHAT:65 | Tag-only system lines. Not usable for free text. |
| `/Script/JagexChatBackend.PlayerChatComponent:Client_ReceivePlayerEvent` | `const FChatPlayerEventData&` | Client, Reliable | OD:45125, CHAT:66 | Tag-based player events. |

Settings: `/Script/JagexChatBackend.ChatDeveloperSettings` (MessageCharacterLimit, SpamDetectionDuration,
SpamDetectionMessageLimit, ...). Cheats: `DominionCheatManager:domEnableChat(bool)` and
`domSpamChat(int32)` (DOM:20088, DOM:19965). `DominionPlayerController:IsChatEnabled()`.
Client UI classes (`UChatWidget`, `UChatUIAPI`, `WBP_Chat`) are client-only and irrelevant on the server.

**Confidence: HIGH** that `Server_SendChatMessage` is the client-to-server chat path: it is the only
Server RPC carrying a message body, and there is no other chat class in Dominion. The open question
is whether `RegisterHook` can read the nested struct param. `describe()` in hooks.lua will log a
`GetFullName`/`tostring`, which may not show `MessageBody`. A follow-up hook should read
`param:get().MessageBody:ToString()` explicitly.

### 2.4 Server "say" (companion speech) options, ranked

1. **Call `Server_SendChatMessage` server-side** on any player's `PlayerChatComponent`, with a crafted
   `FChatMessageData` (MessageBody = text; SenderData = the companion's identity, or reuse a
   real player's with a different Color). On the server a Server RPC runs locally, so the server's
   normal broadcast logic should fan it out to every client. Risk: `_Validate` may reject a
   sender that does not match the owning connection, or the client may show no name for an
   unknown `PlayerId`/NetId. Confidence MEDIUM.
2. **Call `Client_ReceiveChatMessage` on each player's `PlayerChatComponent`** (iterate all
   `DominionPlayerController`s). This skips the server's validation and should put a line in each
   client's chat box. The sender name shown depends on how the client resolves `SenderData`, which
   is unknown. Confidence MEDIUM.
3. **Fallback toast:** `/Script/Dominion.DominionPlayerController:Client_DisplayTextNotification(const FGameplayTag& NotificationTag, const FText& Text)`
   (UHT: BlueprintCallable, Client, Reliable; OD:73027). Shows arbitrary text as an on-screen
   notification, not in chat. It needs a valid notification tag; take one from a hook or the
   enums/tags. Confidence MEDIUM-HIGH that it shows free text.

## 3. Interaction and item pickup

The flow implied by the dump: the client's `UInteractableDetectorComponent` picks the target,
then the client calls **`UPlayerInteractionManager::Server_RequestInteraction`**. The server
validates it and broadcasts the target `UInteractionComponent`'s `OnInteractionEvent(Player)`, which
the owning actor has bound (`ARuntimeSpawnedWorldItem::HandleInteraction`,
`ABaseInteractableResource::OnInteraction`, and others). The actor then grants or drops the item(s).
Foliage pickups (sticks, stones, plants) are ISM instances, converted to actors on demand
(`UInteractableFoliageFunctionLibrary::Convert*`, DOM:24499), then go through the same path.

Ranked candidates:

| # | Path | Params | Ref | Why / confidence |
|---|---|---|---|---|
| 1 | `/Script/Dominion.PlayerInteractionManager:Server_RequestInteraction` | `UInteractionComponent* InteractionComponent, const UPrimitiveComponent* Collider, bool bIsSecondaryInteraction, bool bIsRelease` | OD:64357, DOM:30017; UHT: BlueprintCallable, **Server, Reliable** | **The** generic interact RPC (all E-press interactions: pickups, gatherables, chests, stations, doors). Fires once on press and once on release (`bIsRelease`). The component's outer actor identifies what was used. HIGH. |
| 2 | `/Script/Dominion.PlayerInteractionManager:Multicast_AcknowledgeInteractionRequest` | `UInteractionComponent*, bool bIsSecondaryInteraction, bool bIsRelease` | OD:64362; UHT: NetMulticast, Reliable | The server's accept of #1. Logs only accepted interactions. HIGH. |
| 3 | `/Script/Dominion.RuntimeSpawnedWorldItem:HandleInteraction` | `ADominionPlayerCharacter* Interactee` | OD:66888, DOM:12123 | Picking up a **dropped/spawned world item** (`ARuntimeSpawnedWorldItem : AWorldItem`, holds `ItemData`, stack). Delegate-bound handler. HIGH for dropped loot. |
| 4 | `/Script/Dominion.BaseInteractableResource:OnInteraction` | `ADominionPlayerCharacter* PlayerCharacter` | OD:48310, DOM:8958 | Gathering **pick-up resources** (`AGatherableResource`, `AHarvestableResource`, `AAnimatedResource`, `ASalvageableResource`, BP `BP_BaseGatherableResource_C`). Owns `ItemData` and `ItemDropComponent`. HIGH. |
| 5 | `/Script/Dominion.BaseInteractableResource:DropItems` | `ADominionPlayerCharacter* PlayerCharacter` → `bool` | OD:48320, DOM:8962; UHT: BlueprintCallable | Called from #4 if called through reflection. MEDIUM (it may be a direct C++ call). |
| 6 | `/Script/Dominion.SentientResource:OnInteraction` | `ADominionPlayerCharacter* Player` | OD:67113, DOM:12211 | "Sentient" resources (ones that run away). LOW priority. |
| 7 | `/Game/Gameplay/World/Spawners/GatherableResources/BP_BaseGatherableResource.BP_BaseGatherableResource_C:BndEvt__BP_Spawner_Potato_InteractionComponent_K2Node_ComponentBoundEvent_0_OnInteraction__DelegateSignature` | `ADominionPlayerCharacter* Player` | OD:264010 | Blueprint bound event on the BP gatherable. Script function, so the hook should fire. MEDIUM. |
| 8 | `/Script/Dominion.MagneticComponent_GrantItem:OnRep_SpawnedItem` | — | OD:60894 | RepNotify. Fires client-side, not on the server. Not hooked. |
| 9 | `/Script/Dominion.ProgressComponent:Client_OnItemFirstPickup` | `const UItemData*` | OD:73498 | Client RPC, first pickup only. Not hookable on the server, but proves "pickup" exists as a concept. |

Related: `UItemMagnet` (pawn, `MagnetRange`), `UMagneticComponent::BP_MagnetizeToPlayer(Player, bIgnoreMinTimeBeforeMoving)`
and `DelayedMagnetizeToPlayer(...)` (DOM:26696-26697): items fly to the player and are granted on contact
(auto-loot). `DominionPlayerController:Server_AutoMagnetizeItems(int32 bitflags)` only sets the
preference and is not a pickup.

## 4. Inventory

### 4.1 Classes

- `/Script/Dominion.InventoryComponent` (`UInventoryComponent : UActorComponent`), DOM:24659. Storage:
  `TArray<UItem*> ItemSlots` (0x168), `MaxSlotCount`, `bAllowAdds`/`bAllowRemoves`. Delegate
  `OnInventoryChanged(UInventoryComponent*, AddedItems, RemovedItems, ChangedItems : TArray<FInventorySlotChange>)`.
- `UInventoryWithLogComponent : UInventoryComponent` (DOM:25126). Adds `OnNewLogEvent(UInventoryLogEvent*)`
  and `LogEvents`. Subclasses: `UPersonalInventoryComponent` (DOM:29048), `ULoadoutComponent` (equipment),
  `UPagedInventoryWithLogComponent`.
- Log events: `UInventoryLogEventAddedItem`, `...RemovedItem`, `...MovedItem` (`Item`, `TargetInventory`,
  `TargetSlotIndex`, plus `SourceInventory`/`SourceSlotIndex` for moves), DOM:24821-24843.
- `/Script/Dominion.InventoryController` (`UInventoryController`, on the PC, DOM:24740): all client
  inventory **RPCs** (move, split, drop, destroy, use, craft, repair, consume for building).
- Item instance: `/Script/Dominion.Item` (`UItem`, DOM:25230): `Count`, `Durability`, `GameplayTags`, `Guid`,
  `ItemData`, plus `GetStackSize()`, `BP_GetItemData()`, `GetPlayerFacingName()`.
- Item definition: `/Script/Dominion.ItemData` (`UItemData : UDominionDataAsset`, DOM:25279): `Name` (FText),
  `MaxStackSize`, `Weight`, `Category` (tag), `PickupXPEvent`. Subclasses: `UEquipmentData`, `UFuelItemData`,
  `UConsumableItemData`/`UFoodItemData`/`UPotionItemData`, `UJournalItemData`, ...
- Item-data assets are loaded at runtime with paths like
  `/Game/Gameplay/Items/Resources/Mineral/ITEM_Resources_Stone.ITEM_Resources_Stone` (ItemData) and
  `/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Wood_Oak.ITEM_Resources_Wood_Oak` (FuelItemData).
  The dump has 254 `*ItemData /Game/...` instances. `FindObject`/`StaticFindObject` on these paths gives a `UItemData*`.

### 4.2 Reading a player's inventory

From a `DominionPlayerController` (`FindAllOf("BP_PlayerController_C")`):
`pc:GetInventory()` → `UInventoryComponent*` (UHT: BlueprintPure), or read `pc.InventoryComponent`.
Also `pc:GetPersonalInventory()` and `pc:GetLoadout()`. Then:

- `inv.ItemSlots` (TArray<UItem*>, may contain nulls), or `GetAllItems(TArray<UItem*>& ItemsOut)` / `GetItemSlots()`.
- Per item: `item.ItemData:GetFullName()`, `item.Count`, `item.Durability`.
- `GetNumItemsByData(const UItemData*)` → int32 (BlueprintPure). This is the "verified state" check for gather/give.
- `GetNumEmptySlots()`, `CanAddItemByData(ItemData, Count)` → bool.

Which component is the main backpack versus the hotbar or equipment is **[UNVERIFIED]**. Log all three on a test.

### 4.3 Giving an item server-side (Phase 3 gate), ranked

1. `/Script/Dominion.InventoryComponent:AddItemByData` (OD:58849, DOM:24736; UHT: BlueprintCallable, returns `bool`):
   `(const UItemData* ItemData, int32 Count, float DurabilityPercentage, const FGameplayTagContainer& GameplayTags)`.
   Call it on Luis's `pc:GetInventory()` with a `UItemData` found by path (e.g. `ITEM_Resources_Stone`),
   `Count=5`, `DurabilityPercentage=1.0` (0-1 or 0-100 is unknown; try 1.0 first), empty tag container.
   Verify with `GetNumItemsByData`. Replication: `ItemSlots` has `OnRep_ItemSlots`, so the client should update. **HIGH.**
   Variants: `AddItemByDataToSlot(ItemData, SlotIndex, Count, Durability, Tags)`, `AddItemsByData(TArray<UItemData*>, TArray<int32>, Durability, Tags)`, `AddItem(UItem*)`.
2. `UItemHelperLibrary::SpawnAndLaunchItem(WorldContext, const FItemSpawnParameters&)` (DOM:25422): spawns a
   world item that magnetizes to the player. It looks like "dropping loot", but the struct layout must be built first. MEDIUM.
3. `DominionCheatManager:domAddItem(FString ItemName, int32 Count, int32 DurabilityPercentage)` (OD:72144, DOM:20125;
   UHT: BlueprintCallable, **Exec**). This needs a CheatManager instance on Luis's PC (normally null on a
   dedicated server unless cheats are enabled), and it may run client-side logic. Useful only to learn
   the item-name format. LOW.

Removal / transfer (for `give` from the companion later): `RemoveItemByData(ItemData, Count)` → bool,
`MoveItem(SlotIndex, TargetInventory, TargetSlotIndex, Instigator, Amount)`,
`InventoryController:Server_MoveItemBetweenInventories(SourceInv, SourceSlot, TargetInv, TargetSlot)` (OD:58937; Server, Reliable, WithValidation).

### 4.4 Inventory-change hooks

| Path | Params | Ref | Notes |
|---|---|---|---|
| `/Script/Dominion.DominionPlayerController:OnNewInventoryChangedLogEvent` | `UInventoryLogEvent* LogEvent` | OD:72912, DOM:10283; UHT: BlueprintCallable | Delegate-bound handler of `OnNewLogEvent` on the player's log-inventory. Fires once per add/remove/move, and the log event's class says which. **Best "inventory_add" observer**, if it is bound on the server (it may be bound only for client UI). MEDIUM-HIGH. |
| `/Script/Dominion.InventoryComponent:AddItemByData` / `:AddItem` / `:AddItems` | see 4.3 | OD:58849/58855/58838 | Fire only on reflection calls (Blueprint pickups/loot). MEDIUM-LOW, cheap. |
| `/Script/Dominion.InventoryController:Server_MoveItemBetweenInventories` | see 4.3 | OD:58937 | Fires when Luis drags items between chest and bag. Proves the RPC param logging works. HIGH (on that action). |

## 5. Teleport (Phase 3 gate), ranked

1. **`/Script/Engine.Actor:K2_TeleportTo(FVector DestLocation, FRotator DestRotation)`** → bool (OD:254, Engine.hpp:9698)
   on Luis's `BP_PlayerCharacter_C`. Called on the server with authority, the CharacterMovement
   correction should snap the client. HIGH, standard UE. Alternative: `K2_SetActorLocation(NewLocation, bSweep, SweepHitResult&, bTeleport=true)` (OD:290).
   Risk: Dominion uses a Mover-style movement (`EDomMoverActionTypeIndex`, DOM:20671), so a raw
   set-location could be fought by client prediction. In that case use option 2.
2. **`/Script/Dominion.TeleportationSubsystem:TeleportWithParams`** (OD:69769, DOM:35915; UHT: **BlueprintAuthorityOnly**, BlueprintCallable, returns bool):
   `(ADominionPlayerCharacter* PlayerCharacter, FPlayerTeleportParams& TeleportParams, FTeleportToNamedLocationResult Callback)`.
   `FPlayerTeleportParams` (DOM:6086): `FName LocationName; AGraveyard* OptionalGraveyard; FVector TargetLocation; FRotator TargetRotation; bool bShowLoadingScreen, bVFXOnTeleportStart, bVFXOnTeleportEnd, bIsATest, bNoCheck; ETeleportationType TeleportationType; float TeleportBeginVFXDelayOverride; bool bDropAnyLoadoutExclusiveEquipment`.
   This is the game's own server-authoritative teleport (it handles loading screen and VFX
   multicasts, `Multicast_NotifyPlayTeleport*VFX`). Passing the delegate param from Lua may be
   awkward. MEDIUM-HIGH. Also `TeleportToNamedLocation(PlayerCharacter, FName LocationName, Callback, bShowLoadingScreen, ETeleportationType, AGraveyard*)`.
3. `/Script/Dominion.DominionPlayerController:Server_TeleportToPlayerStart()` (OD:72840; Server, Reliable): no params, sends the player to spawn. The simplest possible gate test. HIGH that it works, but the destination is fixed.
4. Others: `UBaseTeleportationComponent::Server_TryTeleport(FGuid FromId, FGuid ToID)` (lodestones; DOM:15975),
   `UPlayerRespawnComponent::Multicast_Respawn(FVector, FRotator)` (DOM:30461), cheats
   `domTeleportTo(float X, float Y, float Z)` and `domTeleport(FString LocationName)` (DOM:19958-19959).

## 6. Gathering, damage, crafting (later phases, names only)

- **Trees:** `AFellableTree : ADestructibleWorldActor` (DOM:10705), `AFelledTree`, `ATreeLog`/`ASplittableTreeLog`.
  Chopping is damage: `ADestructibleWorldActor` has `HealthComponent` (`UWorldActorHealthComponent`),
  `DamageComponent` (`UWorldActorDamageComponent`), `ItemDropOnDestructionComponent`, and
  **`OnHealthChanged(float CurrentHealth, float PreviousHealth, float MaxHealth)`** (OD:52377, DOM:9318), which is
  delegate-bound and fires per hit. Trees also have `ForceSplitIntoLogAndStump()` and `ForceReduceToStump()`.
- **Rocks/ore:** `ADestructibleMiningRock`, `ADestructibleRuneEssenceRock` (DOM:9283), `AOreNode` (DOM:11556, own `DamageComponent`, `NodeHealth`).
- **Pick-up resources:** `ABaseInteractableResource` family (section 3). **Farming:** `Server_TryHarvestPlot(uint64 PlotID, float YieldMultiplier, ADominionPlayerCharacter* Instigator, bool bIsManual, const UHarvestToolEquipmentData* Tool, bool bCondenseYieldToOneItem)` (DOM:22224).
- **Damage:** `UDamageComponent` (DOM:18376): `ApplyDamageFromGameplayEffect(const FDominionDamageEvent&, bool bShowDamageFloatieIfZeroDamage, bool bMulticast)` (BlueprintAuthorityOnly),
  `Multicast_ApplyDamageFromGameplayEffect(FDominionDamageEvent, EDomDamageFloatiesStrategy)`, `Multicast_ApplyPointDamageFromGameplayEffect(...)`,
  delegates `OnDamageReceivedDynamic(AActor* Target, FDominionDamageEvent)`. Health: `UHealthComponent` (DOM:23641):
  `AuthoritativeHealth`, `MaxHealth`, `IsDead()`, `DecreaseHealth(float, FString Context)`, `OnDeathDynamic`.
  Player attacks are not plain RPCs. They go through the Mover/action stream (`Client_ConfirmActionId`,
  `UPlayerAttackComponent::Multicast_PerformAttackOnSimulatedProxies(AttackId, DataIndex, Forward, ...)`, DOM:29337),
  so the companion's attacks will need either damage application or AI attack paths (`ADominionAICharacter`).
- **Crafting:** `/Script/Dominion.InventoryController:Server_CraftRecipe(UCraftingStationComponent* CraftingStation, URecipeData* Recipe, int32 Count, int32 BonusCount, float XPMultiplier, float BonusXPMultiplier, const TArray<UInventoryComponent*>& Inventories)` (UHT: Server, Reliable, WithValidation),
  plus non-RPC `CraftRecipe(...)` with the same params, and `OnCraftingResult(ECraftingResult, URecipeData*, int32)`.
  Station: `UCraftingStationComponent` (DOM:18126). Recipes: `URecipeData` (DOM:31900). Processing stations: `Server_ToggleProcessing(UProcessingStationComponent*)`.
- **Building:** `UBuildInteractionComponent::Server_Interact(uint32 PieceID, EBuildInteractionType, TArray<UInventoryComponent*>, FVector)` and
  `Server_InteractActor(...)` (DOM:16117-16118), plus `UBuildPlacementComponent` and `UBuildValidationComponent` on the PC.

## 7. What was put in hooks.lua (M.PENDING)

Tags: `chat` (2), `chat_event` (1), `interact` (2), `item_pickup` (4), `inventory_add` (4), `harvest_hit` (1).
None are tick or movement functions. All are per-user-action RPCs, delegate handlers, or authority helpers.
`Client_ReceiveChatMessage` was **not** hooked because it would not run on the server. It belongs to the "say" experiment.

Suggested Phase 2 test (one instruction per step to Luis): (1) type `!ping` in chat, (2) pick up a
stick or stone off the ground, (3) pick up an item he dropped, (4) chop a tree twice. Then read
`hook` events by tag. If `chat` logs only an object name for the struct, add a dedicated handler
that reads `MessageBody`.
