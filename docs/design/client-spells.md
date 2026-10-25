# Design note: spells through the real player path (R2.20)

Status: **rev 2**, after review aa990d09b7e96fb65 (CHANGES-NEEDED: 5 items, all applied below under "Review changes"). Phase A probes are done (read-only).

## Goal (what Luis will see)
- Claude knows which spells he has, what each does (the game's own description), what it costs, and whether he can cast it right now. When he can't, he says why ("I've only got 3 Air runes, Windstep needs 5", "Summon Shelter needs Construction 20, I'm level 1").
- When the model decides a spell fits (from descriptions, never a code rule), Claude casts it the way a player does: **Q** opens the wheel, a **number key** picks the slot, and for placed or aimed spells **left click** places or releases it. The result is verified from game state and reported truthfully.

## Facts from Phase A (live, read-only, 2026-10-25 20:05 UTC; DISCOVERIES "Client spells (R2)")
- Unlocked: **only Windstep** (`USD_Windstep`, Instant, 5 Air, 3 s cooldown, perk Agility 5). It is on wheel slot 0 and is the current selection. Skill levels read at 20:10 UTC were Agility 5 and Attack 5, so the perk requirement is met. The UI's `GetSpellDisplayInfo(0)` reports `bIsUnlocked = true`.
- Wheel: `pc.SpellcastingComponent.SelectedSpells`, 4 radials × 12 slots.
- Runes carried: Air 821, Astral 5452, Earth 5209, Fire 6629, Water 4288, Nature 9659, Law 9999. Luis has already dropped them.
- Key mappings (read from the mapping contexts):

  | Context | Keys |
  |---|---|
  | `IMC_GameplayUI` | **Q** = `IA_SpellMenu` (trigger Released) |
  | `IMC_SpellsUI` | **1–8** = `IA_Spellcasting_QuickAccess0..7`, Q, P = spellbook |
  | `IMC_RadialSelection` | LMB = `IA_SpellsMenu_AcceptSelection`, F/G = previous/next radial, Right2D = `IA_SpellsMenu_SelectSlot` |
  | `IMC_SpellcastingMode` | **LMB** = `IA_Spellcasting_PlaceSpell` (trigger Released), Esc = `IA_Spellcasting_Cancel`, mouse wheel = `IA_Spellcasting_AdjustSpell` |

- Input modes: `DIM_RadialMenu`, `DIM_SpellcastingMode` and `DIM_SpellPlacementMode` (`pc.CurrentInputMode`).
- The game's own UI truth per wheel slot is `HUDUISubsystem.SpellcastingAPI:GetSpellDisplayInfo(slot)` (BlueprintPure). It carries name, `DescriptionText`, cost, `SpellItemsMissing`, `bIsUnlocked`, the special-requirement text and the cooldown.
- Cooldowns: `pawn.PlayerUtilityMagicComponent.LastCastTimeBySpellData`.
- Cast state: `SpellBeingPreparedOrCast` (replicated).
- Failure signals the client receives:
  - `Client_NotifySpellOnCooldown` (Client RPC, post-hook only);
  - the `OnSpellFailedNoAmmo` delegate;
  - `Client_CancelSpellcasting`.

## Review changes (rev 2)
1. **Spell resolution never substitutes.**
   - Exact (case-insensitive) display name or asset first.
   - Then a typo match (normalised edit similarity >= 0.8), only when exactly one unlocked spell qualifies.
   - Otherwise `unknown_target` / `ambiguous_target` with `data.candidates` (the unlocked spell names).
   - `data.spell` always names what was actually cast.
2. **Safety floor (never hurt players; category (c)).** A spell is *harmful* when its game-data modules include a damage module (class word contains `Damage`, e.g. `SpellModule_DamageByEquipment`).
   - A harmful spell whose target is a player is refused with `unsafe`.
   - So is one whose landing point (Instant: Claude himself; Placed/Aimed: the aim point) has a player within the spell's radius. The radius is the `Shape` module's radius if present, else 5 m.
   - No spell names are involved.
3. **Targets.**
   - Instant spells land on Claude; a `target` is ignored and reported.
   - Placed spells with a target: the aim is the camera (`PlayerCameraManager:GetCameraLocation`) looking at the target point via the control rotation, within `MaxDistanceFromCameraToPlaceSpell` (15 m) of the camera, else `too_far`. Verification reads the new `OurSpellActors` actor's location as `data.landed_at` plus `data.landed_dist_m` from the target. The result is `ok` even if it landed elsewhere, but the distance is always reported.
   - Aimed spells (projectiles): same aim; `landed_at` is not observable, so `effect_verified = false`.
   - Without a target, both cast "in front of me", and the manifest says so.
4. **One source of truth in the brain.**
   - No new digest line and no get_state field.
   - The client `spells` handler answers the shape `brain/spells.py SpellBook` already consumes: `data.spells = [{id, name, role, use_when, castable, reason, remaining_s, ...}]`.
     - `use_when` is the game's own description; `role` is the cast type.
     - `reason` is `not_enough_resources` | `on_cooldown` | `not_unlocked` | `not_on_wheel` | `busy` | `falling`, plus a `detail` sentence.
   - Reflex rules (`set_reflex_rule`) are not on the client body. Capabilities list only implemented tools, so the brain never offers them. A rule action `cast` comes with the rules port (out of scope here).
5. **Arbiter, persistence, cleanup.**
   - `cast` is a **waiter** (`kind = "waiter"`, like `drop`), not an action. It does not take the bridge's action slot, so a running follow or gather is never `interrupted` by the bridge. This matches `broker.NON_PREEMPTING` (cast runs alongside a move).
   - Pawn ownership: `arbiter.request` at level **3.5** (above command/task, below reflex), `resumable`. A follow, go_to or gather owner is *suspended* (move snapshotted) and resumed on release. `data.preempted` / `data.resumed` report it.
   - While a reflex owns the pawn (a fight), the cast is refused with `busy` ("I'm fighting"). That is the game-time truth for v1.
   - Cleanup on every exit (ok, fail, expire): if the input mode is not `DIM_Gameplay`, tap the mode's cancel (`IA_Spellcasting_Cancel`), then release the arbiter.
   - Under `DW_PAUSE`, no game calls are made (pause rule). The bridge drops waiters, and the 5 s arbiter lease expires by itself.
   - Prefer the game's own fields: cooldown from `LastCastTimeBySpellData` vs `GameState:GetServerWorldTimeSeconds()`, falling from `CharacterMovement:IsFalling()`, busy from `SpellBeingPreparedOrCast` / `pc.CurrentInputMode`. A pre-check that might be stale never blocks; the attempt and its verification decide, and the result reports what the game showed.
   - No expected effect in the catalog: verify on runes and cooldown only, with `effect_verified = false`.

## Approach (layers, files)
- **New module `client_mod/scripts/spells.lua`** (owned by this agent). It is pure reads plus input injection through the shared `combat._inject` helper (EnhancedInput `InjectInputVectorForAction`, the same call as attack and interact).
  - `list(log)`: one row per unlocked spell, built from game data only.
    - Fields: name, the `DescriptionText` / perk description, cast type (instant, placed, aimed), rune cost vs carried, cooldown left, wheel slot.
    - `castable` plus `why_not` codes: `no_runes{rune, have, need}`, `cooldown{s}`, `not_on_wheel`, `slot_beyond_quick_keys`, `falling`, `busy_casting`, `needs_level{skill, level}` from `PerkUnlockInfo`.
    - `all = true` also lists locked spells with their unlock requirement, so Claude can say "I can't, I need X".
  - `cast(log, {spell, target?})`: an async action through `arbiter.request` at level `command`.
    1. Resolve the spell by name or asset among the unlocked spells, using fuzzy name matching against game data. This is not a phrase table.
    2. Check `castable`. If it fails, return the reason and a sentence in `data.detail`.
    3. If the spell's wheel radial is not the current one, inject F/G.
    4. Tap **Q** (one frame, so Released fires). Wait for `DIM_RadialMenu`. Tap the quick key for its slot.
    5. Instant spells: done. Placed or aimed spells: face the target with the move.lua facing nudge (as gather and interact do), wait for `DIM_SpellcastingMode` / `DIM_SpellPlacementMode`, then tap **LMB** (`IA_Spellcasting_PlaceSpell`). On any timeout, inject Esc (`IA_Spellcasting_Cancel`).
    6. **Verify**: the rune count fell by the cost, `LastCastTimeBySpellData[spell]` changed, and, from the catalog modules, the expected effect appeared. Effects are a GE instance on the pawn (e.g. `GE_Windstep`), a new `OurSpellActors` entry (shelter) or the Windstep gameplay tag. The cooldown RPC and the no-ammo delegate become truthful failure reasons.
  - Exports: `HANDLERS = {cast, spells}`, `MANIFEST`, `NEEDS`. Honours `_G.DW_PAUSE`. (rev 2: no `state_extras`.)
- **`client_bridge.lua`**: `"spells"` is in `M.MODULES` (done by capability agent ad944baba20421147).
- **Brain:** nothing. The tool list comes from the manifest; `SpellBook` reads `spells`.
- **Data:** none new. Names, descriptions, costs and requirements are read live from `UtilitySpellData` / `SkillPerkData`. `data/spells_26161880.json` is used only for the "expected effect" kind (GE class, utility actor class) to verify against, and is optional.

## Precedent
- Same shape as our own verified paths:
  - attack: inject `IA_PrimaryAction`;
  - interact: inject `IA_Interact`;
  - equip: hotbar key.
- Epic: `InjectInputVectorForAction` runs the action's triggers and modifiers as real input.
- MINDcraft-style composite command with verification (ARCHITECTURE 8.6).
- Game controls (allthings.how spellbook-and-wheel guide; dragonwilds.runescape.wiki/w/Spells): Q opens the wheel, click a spell to select it, P opens the spellbook, spells unlock at skill levels, and spells cost runes.
- No existing Dragonwilds or UE4SS spellcasting mod was found.
- Decision: **adapt** our input-injection helper; **build** the thin state machine (about 250 lines).

## Generality check
- No spell names in code. Every spell's row comes from game data, and the cast path depends only on `CastType` (Instant, Placed, Aimed, AllowMovementThenCastInstant) and the wheel slot.
- The next spell Claude unlocks appears in `spells` and is castable with no code change.
- The model decides when to cast from `DescriptionText`. There is no "cast X when Y" anywhere, and no veto of the model's choice. The only gate is the game's own: runes, cooldown and unlock.

## Principles touched
- None bent. There are no Server_* calls: `Server_UpdateSpellData`, `Server_NotifyPreparingSpell` and the rest are never called. Nothing is spawned or granted, and outcomes are only read.
- Open point: putting a newly unlocked spell onto the wheel needs the spellbook UI's drag and drop. The real path is P, then drag. That is Phase C; until then `why_not = not_on_wheel` is reported truthfully.

## Acceptance tests
- **Offline:** `client_mod/tests/test_spells.lua` with a fake engine.
  - List: unlocked, locked with the level reason, no runes, cooldown.
  - Cast: an instant spell happy path; a placed spell (enters placement mode, then LMB); no runes; cooldown RPC; wheel never opens (timeout, then Esc); interrupted by a reflex; `DW_PAUSE`.
  - Held-out: a spell absent from the catalog JSON still lists and casts.
- **Bridge:** a `test_client_bridge.lua` case for `capabilities` (cast/spells present) and the `spells` digest field.
- **Live (one at a time, main's go-ahead):**
  1. `spells` read, with no input.
  2. Cast Windstep on flat ground near Luis. Expect Air 821 → 816, a `LastCastTimeBySpellData` entry, and GE_Windstep / the Windstep tag on the pawn. Luis's eyes: did Claude glow or jump higher?
  3. A placed spell is **blocked**: Claude has none unlocked yet (Summon Shelter needs Construction 20, Magical Mending Artisan 56). It waits for unlocks.
- **Small real-model eval** (≤ 6 Haiku calls, stated before running):
  - "can you get up there?" and the held-out phrasing "jump that wall", each with a ledge in perception, should choose `cast Windstep` from the description alone;
  - "make a shelter" should get a truthful "I can't yet: Construction 20".
