# M2 spell gap audit: every spell vs the M2 cases (2026-10-26, offline)

Scope: the M2 targets "spells used to purpose" (T1 `t1_spell_use.json`, 38 cases), the every-spell stress test
(`stress_spells.json`, 127 cases over 39 spells: combat / cooldown_pressure / low_runes / out_of_reach / moving_target),
the T0 cast cases (`t0_spells.json`, 39), and the spell side of the tactics cases (`goal_cases/tactics_knowledge.json`).
Sources: `data/spell_effects.json` (52 assets: 38 unlocked + 1 locked in scope, 13 n/a), `data/spell_mechanics.json`,
`client_mod/scripts/spells.lua`, `evals/bench/devtarget.py`, `evals/bench/dev_places.json`, DISCOVERIES (to 19:41 UTC),
wiki/guides (below). Build 26161880 (server) / 26162923 (client). Nothing here was run live.

## 1. Spell list check

- **In scope: 39 spells** (38 unlocked + Fishnado, locked). This matches the T0 and stress case sets.
- **The 13 n/a assets** have no unlocking perk, or no perk and no rune cost: CabbageRain, DetectOreAlt, EnchantChefsTools, EnchantWeapon_Earth, GetWaterFromWaterSource, MagicFocus, RapidGrowth (the PerkSpell duplicate), ShadowVeil, SiphonAnimaCharge, SiphonRunes, WeaponBarbs, WeaponPoison, Whetstone.
- **Web check:** the guides list about 26 utility spells by skill (gamever, beebom, metabot, hostedgg), all of them inside this set. The wiki pages for Surge and Confuse add facts used below.
  - Surge: 3 charges for 2 min; a charge makes a dodge travel 8 m.
  - Confuse: range 40 m; the target attacks other aggressive monsters within 30 m for 45 s; some bosses are immune.
- No released spell was found outside the manifest.

## 2. Gap table

Columns:
- **Cast:** the cast type, and whether spells.lua can cast it. spells.lua handles all four EUtilitySpellCastType values (instant, placed, aimed, instant_after_move), with target = self, a look id, or a point, plus approach-to-range and walk_to.
- **Fixture T0 / T1:** whether the case's precondition is set up. "none needed" means nothing is required.
- **Success read:** whether the T0 proof (spell_effects `proof.effect`) has an observable on the dev path.
- **Live:** whether DISCOVERIES or spell_effects has a live observation.

| Spell | Cast | Fixture T0 / T1 | Success read | Live |
|---|---|---|---|---|
| Personal Chest | instant ✓ | none needed / **T1 has no item in personal storage** | ✓ referee spell_state | ✓ 07:35Z |
| Axtral Projection | aimed at a thing ✓ | T0 ✓ (axe + standing_trees) / **T1 no tree scene** | ✓ spell_actor, target health | cast in mock only |
| Bones to Peaches | placed ✓ | ✓ ground_item bones (both) | ✓ spell_actor | no |
| Confuse | aimed at a creature ✓ | **no creature in either case** (needs 2 aggressive mobs within 30 m) | ✗ needs_live_observation → **new body read `target_effects`** | no → check `spell_confuse_observe` |
| Spectral Arrows | instant (bow held) ✓ | ✓ bow grant + hold / **T1 "killed ≥ 2": no enemies spawned** | ✓ held_item_effect | no |
| Summon Elemental Spirits | instant ✓ | none needed / **T1 needs an anima vent within 400 m (no dev place)** | ✗ needs_live_observation | no → `spell_detect_anima_vents_observe` |
| Summon Stone Spirits (DetectOre) | instant ✓ | none needed / T1 needs ore within 200 m (dev spot unknown) | ✓ actor + input mode | ✓ 07:3xZ |
| Divine Rock | placed ✓ | **neither case sets up 5 ore on the ground** (mechanics: drop 5 ore, then cast on them) | ✗ needs_live_observation | no → `spell_divine_rock_observe` |
| Enchant Weapon: Air | instant (melee held) ✓ | ✓ greatsword + hold / **T1 "killed": no enemy** | ✓ held_item_effect | no |
| Enchant Weapon: Fire | instant ✓ | ✓ / **T1 no enemy** | ✓ held_item_effect | ✓ 07:37Z |
| Enchant Weapon: Water | instant ✓ | ✓ / **T1 no enemy** | ✓ held_item_effect | no |
| Enfeeble | aimed at a creature ✓ | **no creature in either case** | ✗ → **new `target_effects`** | no → `spell_enfeeble_observe` |
| Eye of Oculus | instant ✓ | none needed | ✓ view target, referee | ✓ |
| Mucksplosion (Compost) | placed ✓ | **scene `farm_plot` is missing from dev_places.json** (the fixture aborts); does a compost bucket grant hold 150 units? unknown | ✓ spell_actor (world_module has no read) | no |
| Rapid Growth | placed ✓ | **no planted plot in either case** | ✓ spell_actor | no |
| Superheat | placed ✓ | **no fire station** (mechanics: cast on a campfire/furnace...) | ✓ spell_actor | no |
| Fire Spirit | instant ✓ | none needed | ✓ tag + GE | cast ok in the 16:33 dev re-run |
| Fishnado | placed ✓ (fishing node id resolves, 2026-10-26) | **locked**; **no fishing node scene** | ✓ spell_actor | no |
| Fishing Frenzy | placed ✓ | **no fishing node scene** | ✓ spell_actor | no |
| Uproot (Harvest) | instant ✓ | **no grown crops** | ✓ spell_actor (world_module has no read) | no |
| Home Teleport | instant ✓ | ✓ claim_bed (its Bedroll path is **UNVERIFIED**) | ✗ needs_live_observation; the body has `moved_m` | no → `spell_home_teleport_observe` |
| Humidify | aimed ✓ | **farm_plot scene missing**; the watering can grant may be empty (needs 50 water) | ✓ spell_actor | no |
| Infernal Rod | instant (rod held) ✓ | ✓ rod + hold / **T1 needs a fishing spot** | ✓ held_item_effect | no |
| Internal Alchemy | instant ✓ | **no active food buff** (mechanics: does nothing without one) | ✗ world_module only | no → `spell_internal_alchemy_observe` |
| Magical Mending | placed ✓ | ✓ ground_item, worn sword at 40% | ✓ spell_actor | no |
| Phase Dash | instant ✓ | none needed / **T1 "far side" needs a gap scene: none** | ✓ air_dash probe | ✓ 21:33Z |
| Trunk Totem | placed ✓ | **T0 none** / T1 felled_log gives one log (mechanics: needs several) | ✗ needs_live_observation | succeeded once in the re-run → `spell_trunk_totem_observe` |
| Recall | instant_after_move ✓ (walk_to) | **T0 recall_beacon is based on the old two-cast model, now disproved** (live 19:39: a later cast returns 0 m) | body: `returned` / `from_opened_m` ✓ | ✓ 19:38–19:41 (hold-and-walk) |
| Rocksplosion | placed ✓ | pickaxe ✓ / **no rock or ore scene** | ✓ spell_actor | no |
| Runes to Rune Essence | placed ✓ | runes dropped by himself (he did it in the re-run) | ✓ spell_actor | succeeded in the re-run |
| Snare | instant ✓ | none needed / **T1 "moved ≥ 10 m": no chaser spawned** | ✓ spell_actor | no |
| Overdrive | placed ✓ | **no mechanical station** | ✓ spell_actor | no |
| Splinter | placed on a thing ✓ | ✓ felled_log (fixture **UNVERIFIED**) | ✓ actor, target gone, drops | ✓ 21:3xZ |
| Summon Shelter | placed ✓ | none needed (flat ground) | ✓ spell_actor | ✓ 20:44Z |
| Surge | instant ✓ | none needed | ✗ dodge_distance_gain_m had no probe → **new probe `dodge_distance_test.lua`** | cast only (07:3xZ) → `spell_surge_dodge_distance` |
| Tempest Shield | instant ✓ | none needed | ✓ tag + GE | ✓ 21:30Z |
| Bark to Bones | placed ✓ | **T0 has no standing tree** (standing_trees exists but the case doesn't use it) | ✓ spell_actor | no |
| Vengeance | instant ✓ | none needed / **T1 "killed": no enemy** | ✓ tag + GE + actor | cast ok in the re-run |
| Windstep | instant ✓ | none needed / **T1 verbs `ledge` and `player` exist only in the mock** (DevTarget sends them to the server: unknown_verb) | ✓ tag + jump probe | ✓ 21:27Z |

**Counts:**
- spells.lua can cast all 39.
- Success read on the dev path: 31 of 39 before this audit. Body reads added now: Confuse, Enfeeble and Surge (needs live confirmation). Still no read: Summon Elemental Spirits, Divine Rock, Trunk Totem, Internal Alchemy (observation checks queued). Home Teleport and Recall have body reads but no promoted proof.
- Live-observed effects: 11 (Recall included).
- A complete T0 fixture: 26 of 39. A complete T1 fixture: about 14 of 38.

## 3. What was fixed offline (no judge file touched)

1. **`brain/spells.py`** (perception):
   - Blocked rows now carry `castable: false` and `reason`. `Controller.spell_lines` renders those; it never rendered `note`, so a spell on cooldown or out of runes read as castable to the model.
   - Rows whose game requirement is unmet (`reason == "requirement"`, e.g. an enchant with no melee weapon held) are kept, with "needs X first". The model can see that equipping the right thing enables the spell.
   - The body's `how` is carried through.
   - Tests: `tests/test_spells_rules_brain.py`.
2. **`client_mod/scripts/spells.lua`** (small):
   - `W.effects_of(actor)` is factored out of the snapshot. `W.target_effects` reads a creature target's GEs and tags before and after an aimed or placed cast at it, and the cast reply gains `data.target_effects {ge, tags}` (so `effect_verified` is set when something landed).
   - It is UNVERIFIED that creature GEs replicate to the client; the Confuse/Enfeeble checks record this.
   - `state_extras` (get_state.spells) carries `remaining_s`.
   - The `spells` read rows carry `how` from data/spell_mechanics.json.
   - `M.list_added` is the shared multiset diff.
   - Tests: `client_mod/tests/test_spells.lua`, 166 passing.
3. **`client_mod/commands/dodge_distance_test.lua`:** the missing probe for proof kind `dodge_distance_gain_m`. It does one ground dodge through the pawn's own EvadeAction, samples it, and has an `ARGS.read` mode. Adapted from air_dash_test.lua.
4. **Live checks** (all `observe_only`, validated with `live_queue run --dry-run`), under `tools/live_checks/`:
   - `spell_confuse_observe`
   - `spell_enfeeble_observe`
   - `spell_surge_dodge_distance`
   - `spell_detect_anima_vents_observe`
   - `spell_divine_rock_observe`
   - `spell_trunk_totem_observe`
   - `spell_home_teleport_observe`
   - `spell_internal_alchemy_observe`

## 4. Gaps that need main or Luis (judge files or other owners)

- **Fixtures in evals/ (judge):**
  - add a `farm_plot` entry to dev_places.json (Mucksplosion, Humidify; Rapid Growth and Uproot also need a planted or grown plot);
  - add spawns to the T1 cases that need an enemy: Confuse (2 mobs), Enfeeble, the 3 enchants, Vengeance, Spectral Arrows (2 in a line), Snare (a chaser);
  - add ground ore for Divine Rock;
  - add a standing tree for T0 Bark to Bones and a trees scene for T1 Axtral;
  - add station scenes for Superheat (fire) and Overdrive (mechanical);
  - add a fishing-node scene for Frenzy, Fishnado and T1 Infernal Rod;
  - add an active food buff for Internal Alchemy;
  - add DevTarget verbs `ledge` and `player` for T1 Windstep;
  - replace `recall_beacon`, which is now invalid, with a walk_to-style case;
  - decide whether Fishnado is n/a while it is locked.
- **Proofs in data/spell_effects.json (spell proofs = judge):** promote after the checks run.
  - Surge: `dodge_distance_gain_m` now has a probe.
  - Confuse/Enfeeble: `target_effect` once `target_effects` is seen live.
  - Home Teleport: `moved_m`.
  - Recall: a `returned` kind.
- **Stale manifest text:** the `cast` description in spells.lua still says "cast once to set a beacon, again to return". That is wrong since 19:39 (Recall is hold-and-walk). Left for the Recall agent, who owns that part.

## 5. Tactics: which spell when (perception for the model, no rules added)

Checked against `goal_tactics_prep_hard_fight`, the GOAL "use" examples, `brain/spells.py`, `Controller.spell_lines` and `get_state.spells`.

**Present and adequate:**
- creature PL, boss flag and the odds verdict ("much stronger", PL gap);
- known damage-type affinities with their source ("weak to Fire (wiki)");
- enchant spells named by element;
- Tempest Shield "for: blocking big hits";
- Surge `how` "each dodge carries you about 8 m".

**Fixed here:**
- the cooldown / no-runes state was invisible in castable_spells;
- requirement-blocked spells vanished;
- `remaining_s` was missing from get_state.spells.

**Still missing** (report only; no code picks spells):
1. **`how` is not rendered in the Controller context.** `spell_lines` (controller.py, another owner) prints role, for, needs, castable and use_when (80 chars), not `how`. The drop-then-cast and cast-on-a-thing mechanics (Divine Rock: drop 5 ore; Runes to Essence: drop runes; Magical Mending: drop worn gear) are only visible through the `spells` read tool now. The model declined Divine Rock in the re-run for exactly this reason. Recommendation for the controller owner: render `how` (it's about 3.7 k characters for 35 spells, so maybe only for castable rows) or point the model at `spells` in the cast description.
2. **Phase Dash through an attack** (GOAL example): its `for` text says "dashing across gaps mid-air" and its `how` says "air-dash again while airborne". Nothing in perception (or in any source found) says it avoids damage. The model cannot infer this use. It's a data question for spell_purposes (judge-generated); needs a live i-frame observation first.
3. **A Windstep landing stuns low/medium mobs** (GOAL example): not in `how`/`for`. The `wind_stomp` route is unverified (spells_26161880 routes, "no stagger seen on a Kebbit"). Needs a live observation, then a data line.
4. **Dodging or Phase Dash on each telegraph** is a tick-speed decision (defense.lua reflex). The brain can only choose the defense style or prepare. Fine by design, but no case-level perception tells the model that Phase Dash/Surge charges are available to the reflex.
5. **Confuse's needs:** "other aggressive monsters within 30 m" (wiki) is not in `how` ("it attacks other monsters for 45 s"). It's enough to infer that it is useless against a single enemy.

## 6. Search record (search-before-building)

- **Need:** a full spell list; ground-dodge distance probe; target status read.
- **Searched:**
  - "RuneScape Dragonwilds spells list wiki";
  - "Dragonwilds Surge spell dodge distance Phase Dash Confuse Enfeeble effect";
  - the repo: DISCOVERIES, spell_mechanics, the air_dash_test probe.
- **Found:**
  - guides listing about 26 utility spells, all within the manifest;
  - the wiki Surge page (8 m dodge, 3 charges for 2 min);
  - the wiki Confuse page (40 m range, 30 m radius, 45 s);
  - nothing on Phase Dash i-frames or Enfeeble's numbers.
- **Decision:**
  - adapt: the dodge probe is air_dash_test.lua without the jump;
  - reuse: the creature effects read is the snapshot's own GameplayEffectsComponent read, factored into `W.effects_of`.
- **Sources:**
  - https://dragonwilds.runescape.wiki/w/Surge
  - https://dragonwilds.runescape.wiki/w/Confuse
  - https://gamever.io/knowledge-base/every-utility-spell-in-dragonwilds-and-which-skill-hides-it
  - https://beebom.com/all-runescape-dragonwilds-spells/amp/
  - https://metabot.gg/en/dragonwilds/spells
  - https://hostedgg.com/wiki/runescape-dragonwilds/spells
