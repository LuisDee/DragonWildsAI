# Design note: spells through the real player path (R2.20)

Status: **draft for review** (main + fresh-context reviewer). Phase A probes are done (read-only); nothing is implemented yet.

## Goal (what Luis will see)
- Claude knows which spells he has, what each does (the game's own description), what it costs, and whether he can cast it right now. When he can't, he says why ("I've only got 3 Air runes, Windstep needs 5", "Summon Shelter needs Construction 20, I'm level 1").
- When the model decides a spell fits (from descriptions, never a code rule), Claude casts it the way a player does: **Q** opens the wheel, a **number key** picks the slot, and for placed or aimed spells **left click** places or releases it. The result is verified from game state and reported truthfully.

## Facts from Phase A (live, read-only, 2026-10-25 20:05 UTC; DISCOVERIES "Client spells (R2)")
- Unlocked: **only Windstep** (`USD_Windstep`, Instant, 5 Air, 3 s cooldown, perk Agility 5). It is on wheel slot 0 and is the current selection. The UI's `GetSpellDisplayInfo(0)` reports `bIsUnlocked = true`.
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
  - Exports: `HANDLERS = {cast, spells}`, `MANIFEST` (manifest entries for both tools), and `state_extras` for get_state (`spells` compact). Honours `_G.DW_PAUSE`.
- **`client_bridge.lua`** (owner: main or bridge owner):
  - add `"spells"` to `M.MODULES`;
  - call `state_extras` from every module that exports it, not only `skills`. This is a 5-line generalisation.
- **Brain** (owners: capability-contract agent ad944baba20421147 / situation owner):
  - nothing for the tool list, because it comes from the manifest;
  - one `Spells:` line in `brain/situation.py summary`, e.g. `Spells: Windstep (5 Air, have 821; ready) — "jump higher and descend slower"`.
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
- **Small real-model eval** (≤ 6 Haiku calls, stated before running): a case where Luis says "can you get up there?" with a ledge in perception chooses `cast Windstep` from the description alone, and "make a shelter" gets a truthful "I can't yet: Construction 20".
