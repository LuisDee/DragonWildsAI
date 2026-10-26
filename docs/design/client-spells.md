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
- **New module `client_mod/scripts/spells.lua`** (owned by this agent). It is pure reads plus one-frame input injection through the shared `combat._inject` helper (EnhancedInput `InjectInputVectorForAction`, the same call as attack and interact).
  - `spells {all?}` (read): one row per unlocked spell, in the SpellBook shape, built from game data only.
    - Fields: `id` (asset), `name`, `use_when` = `description` (perk description), `role` = `cast_type`, `cost [{item, name, count, have}]`, `remaining_s`, `wheel_slot`, `castable`, `reason`, `detail`.
    - `reason` codes: `not_unlocked` (+ `needs {skill, level, have}` from `PerkUnlockInfo`), `not_on_wheel` (not on the wheel, or beyond quick keys 1–8 of page 1), `not_enough_resources`, `on_cooldown`, `busy` (mid-air or already casting).
    - `all = true` adds the locked spells a perk unlocks.
  - `cast {spell, target?}` (**waiter**, arbiter level 3.5, a resumable pre-emption of follow/gather):
    1. Resolve: exact name or asset, else a unique typo match (>= 0.8), else `unknown_target` / `ambiguous_target` + `candidates`. An exactly named locked spell gives `not_unlocked` + `needs`.
    2. Hard, fresh gates block: unlock, wheel, runes, mid-air. Possibly stale ones (cooldown via the clock mapping, "already casting") do not block. The attempt goes ahead, the server's cooldown RPC and verification decide, and `data.precheck` reports the pre-check.
    3. Safety floor (`unsafe`): see review change 2 and rev-2 point 2 below.
    4. Take the pawn (`busy`, "I can't cast while I'm fighting yet." if a reflex owns it). Tap **Q** (one frame, so Released fires) and wait for `DIM_RadialMenu` (two tries). Tap the slot's quick key. If the wheel is still open after 1 s, confirm with `IA_SpellsMenu_AcceptSelection` once.
    5. If a spell mode opens (placed or aimed): **aim the camera** at the target point (control rotation from `PlayerCameraManager` location; `too_far` beyond `MaxDistanceFromCameraToPlaceSpell`). Without a target, cast in front of me. Tap **LMB** (`IA_Spellcasting_PlaceSpell`).
    6. **Verify** (within 4 s): runes fell or `LastCastTimeBySpellData[spell]` changed. Effects are reported (new GE instances, tags, own spell actor → `landed_at`, `landed_dist_m`), with `effect_verified` false when none is seen. A targeted spell landing farther than max(3 m, its radius) answers `verification_failed` "it landed N m from where you wanted".
    7. Cleanup on every exit: if a radial or spell input mode is still open, tap cancel; release the arbiter (`data.preempted` / `data.resumed`). No game calls under `DW_PAUSE`.
  - Exports: `HANDLERS = {cast, spells}`, `MANIFEST`, `NEEDS`. Honours `_G.DW_PAUSE`. No `state_extras`.
- **`client_bridge.lua`**: `"spells"` is in `M.MODULES` (done by capability agent ad944baba20421147).
- **Brain:** nothing. The tool list comes from the manifest; `SpellBook` reads `spells`.
- **Data:** none new. Names, descriptions, costs, requirements and the Damage/Shape modules are read live from `UtilitySpellData` / `SkillPerkData`. `data/spells_26161880.json` `usage.role` is an optional data profile for the safety floor (hostile and area-harm roles).
- **Rev 2 point 2 (safety floor, final):**
  - A hostile spell (a Damage module, or role `combat_damage`, `combat_cc` or `gathering_aoe`) is never cast at a player.
  - The proximity check applies only to spells that hurt at the landing point: placed or aimed spells that are harmful or have an area-harm role, and instant spells with both a Damage and a Shape module. The radius is the Shape radius, or 5 m only for placed or aimed spells without one.
  - Self buffs without an area (a weapon enchant) are never refused for Luis standing nearby.

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

## Rev 3 (live run, 2026-10-25 evening)
- **Placed spells choose their own spot** (main's request).
  - Candidates come from traces: rings at 3–9 m around me, or the target, then 2 and 3.5 m rings around it. They are ranked by 3x3 ground spread, with overhead clearance and line of sight checked.
  - Each candidate is confirmed by the **game's own placement preview** (`AUtilitySpellPlacementVisualizer.bCurrentPlacementValid` + `CurrentAdditionalValidationInfo`) before LMB.
  - A "not flat" verdict skips equally uneven candidates for the rest of the cast.
  - If nothing is accepted: `nothing_in_range` / `no_valid_spot`, the game's reason in words, and a `flat_spot` hint 15–30 m away. The model decides whether to walk there.
- **Verification:**
  - Wait through the cast animation (up to 12 s in a spell input mode).
  - A new own spell actor near the preview counts as success.
  - A late watcher (15 s) emits `cast_late_success` activity.
  - A leftover open wheel is closed first.
  - The cooldown uses the client world clock.

## Rev 4: settle before answering, stage timing, short page turns (L25–L27, dev measure run 2026-10-25 23:32)
- **Goal:** the cast reply is as truthful as the harness probe, and as fast as the wheel allows.
- **L25, under-reported late spends:**
  - On Summon Shelter and Eye of Oculus the probe saw runes spent, the cooldown started and the actor spawn, but the reply said `runes_spent=[]` / `cooldown_started=false`.
  - Cause: the reply was built at the first success sign (an actor, or one rune delta). The other signals replicate separately and seconds later. Server property replication is eventual and paced by NetUpdateFrequency.
  - Fix: after the first sign, **poll until both required signals are present** (rune delta if the spell costs runes, and the LastCastTimeBySpellData change), bounded by `settle_s` = 8 s. A spell that keeps its own mode open (Oculus) is left with Esc once, and the poll goes on for `settle_after_leave_s` = 2 s, because its cooldown lands when the mode ends.
  - The reply says `settled: true|false` and `unsettled: [...]`, so a gap is named, never hidden.
  - A valid ground preview up to 4 m off an asked point is accepted (the shelter centres itself 3.2 m off the aim point).
- **L26:** failure details never contain raw ids (`fol:…`, actor names); the id stays in `data.target`.
- **L27, 4–7 s per cast:**
  - Every reply now carries `data.timing` {open_s, pages_s, select_s, aim_s, verify_s, settle_s, total_s, page_turns}.
  - Cuts:
    1. Page turns go the short way. The wheel opens on the last page used, `M.page_of` finds it from the slice icons, and Left/Right is chosen accordingly (up to 2 turns, about 0.9 s, saved).
    2. Page polling: the minimum wait is 0.1 s instead of 0.4 s, then poll until the icons change.
    3. The fixed 3 s post-success wait became the settle poll above, which ends as soon as the state is complete.
  - Unchanged on purpose: the cast animation and the server's spend, which are the game's own time.
- **Tests (fake world with delayed replication):**
  - the actor first, runes at 3 s, cooldown at 5 s, giving one complete reply;
  - a cooldown that never comes gives settled=false, bounded;
  - an own-mode spell leaves the mode, then settles;
  - a 3.2 m offset preview is accepted;
  - one page back instead of three forward;
  - timing is present;
  - no raw id in speech.

## Search record
- **Unreal property replication is eventual:** the server sends changed properties at the actor's net update rate, so a client sees related changes at different times. Epic, "Property Replication", https://docs.unrealengine.com/4.27/InteractiveExperiences/Networking/Actors/Properties; NetUpdateFrequency, https://forums.unrealengine.com/t/net-update-frequency-send-rate/432578.
- **Wait for a condition with a timeout, not a fixed sleep:** Selenium "Waiting Strategies", https://www.selenium.dev/documentation/webdriver/waits. SleepReplacer (Univ. Genoa, SQJ 2022) replaced 81–100% of fixed sleeps with explicit waits and cut suite time by 13–71%, https://iris.unige.it/handle/11567/1099894.
- **Same idea in DOM testing:** Testing Library `waitFor` retries an assertion until it passes or times out, https://testing-library.com/docs/dom-testing-library/api-async/#waitfor.
- **Decision:** ADAPT the explicit-wait pattern (poll our own diff of fresh snapshots each bridge tick, bounded) inside the existing cast state machine. No library is needed.
