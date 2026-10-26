# Stable target ids for foliage (BUGS L26)

Status: implemented offline 2026-10-26 (`client_mod/scripts/sense.lua`, `client_mod/scripts/client_bridge.lua`). Not yet checked live.

## 1. What went wrong

This happened in the first dev measurement run (T0, Axtral Projection; `client_io/bridge/client_to_debug.jsonl` lines 250-263):
1. `explore {about: "tree"}` found `fol:BP_InteractableFoliageISMC_Tree_C_12:59` (Ash Tree, 18.6 m).
2. `cast` on it failed with `too_far` at 22.5 m (the reach is 15 m).
3. `go_to` the same id arrived 1.4 m from the tree.
4. `cast` on the same id then failed with `unknown_target`: "I can't see that tree or plant any more".
5. The model repeated the cycle until the case budget ran out.

The cause is in the game, not in the walk. The server's `NearbyFoliageConverterComponent` (range 300 cm) turns an instanced-foliage tree into a real actor when a player comes within 3 m, and it hides the instance (scale 0). `sense.foliage` skips hidden instances, so the id named nothing any more.

Live evidence: `gather.lua` logs "adopted BP_BM_Tree_Ash_03_C_2147454756 (was fol:BP_InteractableFoliageISMC_Tree_C_9:4)" every time it walks up to a tree (client.log 2026-10-25 20:01, 20:03, 21:05, 21:16).

The old id `fol:<component name>:<instance index>` had two more weaknesses:
- **Indices move.** ISM/HISM `RemoveInstance` swap-removes, so the last instance takes the freed slot.
- **Component names are not unique.** A component name is unique only within its outer, so every World Partition cell's foliage actor has its own `..._Tree_C_12`. Cells also stream in and out as he walks.

## 2. Decision

**The identity is the instance's actor class plus where it stands.** A foliage instance never moves, so its id is:

```
fol:<ActorClass>@<x>,<y>,<z>      whole decimetres, e.g. fol:BP_BM_Tree_Ash_03_C@1084,19495,-313
```

The class is `InteractableFoliageISMComponent.ActorClass`, the actor the instance turns into.

**One resolver:** `sense.resolve_foliage(id)` returns `row, how` or `nil, why`.
1. It looks for the nearest instance of the same class within `FOLIAGE_MATCH_CM` (100 cm) of the encoded point. It queries a 300 cm sphere at that point and includes hidden instances.
   - When the computed id is identical, `how` is `same`.
   - Otherwise (the component was re-streamed or rounded differently) `how` is `reindexed`, and the row carries the new id.
2. If there is no visible instance, it looks for an actor of that class within `CONVERTED_MATCH_CM` (200 cm, the same rule as gather.lua's `adopt_cm`). Then `how` is `converted`: the actor's census resource row, with `converted_from = id`.
3. If neither is found:
   - `felled_or_picked` when a hidden same-class instance stands there;
   - `not_found` otherwise (not streamed in, or nothing there).
4. An old `fol:<component>:<index>` id still resolves by an exact match within 80 m (`how` is `legacy`), so ids handed out before the change keep working.

**Every tool resolves through it.** `client_bridge.lua` `find_thing` (used by go_to, interact, inspect, fetch, cast, the skills engine and the spells target) sends every `fol:` id to `find_foliage`, which calls `sense.resolve_foliage`.
- The census is not scanned for these ids.
- The thing comes back as a normal `resources` thing.
- When `how` is not `same`, it carries `resolved` (`reindexed` / `converted` / `legacy`) and `resolved_from` (the asked id). So the brain sees the id to use from now on, and the old one keeps working anyway.
- Internal fields (`_pos`, `_comp`, `_index`, `_legacy`) are stripped before the wire.
- Failures are `unknown_target` with `why` and a speakable `detail` that contains no raw id (BUGS L26 speech part; the spells agent fixed `cast`'s own sentence).

**Read-only.** The resolver uses the same reflected getters as `sense.foliage`: `GetInstancesOverlappingSphere`, `PerInstanceSMData[i].Transform`, and the component's location, rotation and scale. It also uses `FindAllOf(<ActorClass>)`. There are no struct out-params and no conversion calls.

### Why not the alternatives

- **Keep `component:index` and re-scan the census for the same index.** This is wrong after a swap-remove, wrong across cells, and blind to conversion.
- **A per-session id → (component, index) table refreshed on every census, as the forum workarounds do.** This needs a hook on every add/remove, which the client doesn't see (the server removes, and the client just gets the replicated hide). The table is also lost on a bridge restart.
- **UE5 `FPrimitiveInstanceId`.** It is persistent only "for the lifetime of the instance" within one primitive. It is not serialized, it resets when the proxy is recreated, and it is not exposed as a reflected property we can read from Lua. A position key needs nothing from the engine.

## 3. Tests

- `client_mod/tests/test_foliage_ids.lua` (new, 18 checks, real sense.lua over fake ISM components): id format and parse, same, swap-remove re-index, a re-streamed component (new name, 6 cm off) handed back as `reindexed`, same class only, 1.5 m off is another tree, **converted** (the live case: hidden instance plus an actor 0.5 m off, nearest one chosen), `felled_or_picked`, `not_found`, legacy ids, and census rows without internals.
- `client_mod/tests/test_client_bridge.lua` "L26: a foliage id resolves where the instance stood": inspect returns the converted actor with `resolved` / `resolved_from`, the internals are stripped, the gone reasons carry no raw id in the detail, and go_to walks to the resolved position.
- `client_mod/tests/test_gather.lua` §14: the foliage id expectation moved to the new format.

## Search record

| Question | Source | What it says | Used how |
|---|---|---|---|
| Are ISM instance indices stable? | Epic forum, "[Bug] UHierarchicalInstancedStaticMeshComponent Can not use indices if RemoveInstance is used", https://forums.unrealengine.com/t/bug-uhierarchicalinstancedstaticmeshcomponent-can-not-use-indices-if-removeinstance-is-used/308849 ; issue UE-40693, https://issues.unrealengine.com/issue/UE-40693 | RemoveInstance swap-removes: the last instance moves into the freed slot, so indices held elsewhere go stale | An index is not an identity |
| Does the engine say so? | UE API `UInstancedStaticMeshComponent::SetRemoveSwap`, https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UInstancedStaticMeshComponent/SetRemoveSwap | Swap removal is an optimisation that changes instance order | Same |
| Is there a stable engine id? | UE API `FPrimitiveInstanceId`, https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/FPrimitiveInstanceId ; `FPrimitiveInstanceDataManager`, https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/FPrimitiveInstanceDataManager | Persistent only for the instance's lifetime; the id mapping is not serialized and resets when the proxy is recreated; ID-based adds can't be used on HISM | Rejected: not reflected for Lua, and doesn't survive streaming |
| How do harvest systems key foliage? | Meedee "P1 Foliage Harvest Framework", https://forums.unrealengine.com/t/meedee-studio-p1-foliage-harvest-framework/2838988 | Tracks harvested state "independently from volatile foliage instance indices" so it stays consistent across World Partition streaming, save/load and regrowth | The same idea; we key by class plus position because we only read |
| Swap instance → actor near the player is a standard pattern | "Easy interactive foliage" (UE Marketplace), https://docs.unrealengine.com/marketplace/ja/product/easy-interactive-foliage-physics-blueprint-system ; "Advanced Interact Foliage" (Fab), https://www.fab.com/listings/af39e111-b098-4bc0-8193-1fcc86dedca0 | Foliage instances are converted to Blueprint actors when a player gets near (World Partition aware) | It explains our live case; the resolver adopts the converted actor |
| World Partition foliage actors per cell | UE-157379, https://issues.unrealengine.com/issue/UE-157379 | Instances belong to per-grid-cell InstancedFoliageActors (and can detach across cell boundaries) | Component names repeat per cell, so a name is not a key |

**Choice: adapt.** The pattern (key by stable world identity; adopt the converted actor) is standard. We build only the small resolver. In-house precedent is gather.lua's `adopt_cm`. There is no library to reuse inside UE4SS Lua.
