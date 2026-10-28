# Inventory read completeness: perception wave

Inventory component, page table and held-item reads can fail after returning
some rows. Preserve observed rows and report per-scope `complete`, `partial` or
`unknown` with reasons/gaps. Unknown slot or hand wrappers are not verified
empty; their native representation remains unverified. Read-only counts are
lower bounds whenever relevant slots or quantities are unknown. `unmapped` keeps
carried rows when page mapping cannot be established. Loadout and personal
storage remain separate. Component/controller identity and array length changes
invalidate completeness, though stable values cannot rule out ABA.
If the quick-slot count and component identity are verified before and after,
rows in that prefix remain identifiable as hotbar even if later page traversal
fails. Other unverified rows remain unmapped. Use/equip/move/drop report an
unverified location for an observed unmapped candidate instead of claiming it
is absent or guessing a slot. The survival reflex likewise reports an unknown
location or incomplete inventory rather than asserting nothing is carried.

Expose `read_status` on inventory list and compact inventory and
`inventory_read_status` on get_state. Legacy absent status means unknown.
`carried.count_semantics` is `exact` only for a complete carried read and
`lower_bound` otherwise; known positive count fields remain available.
Observed inventory rows and count fields remain available. A later brain digest
wave must make incompleteness visible to the model; this wave alone does not fix
count-sensitive drop/interact/skills/needs verification. Frozen judges including
`brain/predicates.py` are unchanged; incomplete reads are not completion proof.
No item-specific logic, inventory write or fresh empty-state claim is added.

## Search record

Actual queries `site:docs.ue4ss.com Lua TArray ForEach get UObject IsValid array` and `site:lua.org manual 5.4 pcall errors iteration Lua`. Opened [UE4SS TArray](https://docs.ue4ss.com/lua-api/classes/tarray.html), [UE4SS UObject](https://docs.ue4ss.com/lua-api/classes/uobject.html), and [Lua pcall](https://www.lua.org/manual/5.4/manual.html#pdf-pcall). These describe wrapper methods and Lua error handling, not the game's empty-slot ABI; native faults remain outside Lua pcall. Reuse and adapt existing inventory/bridge read paths, rather than introducing another inventory framework. Independent dev null/occupied controls remain necessary before reporting empty slots or hands as known empty.

Principles: real read paths, generic observations, preserve per-world data and
model choice. Acceptance uses actual Lua modules with fake engine arrays,
including errors after an observed row, page failures, quantities, independent
hands, identity changes and legacy status propagation. Live native controls are
separate; no judge or production-state write is authorized by this note.
