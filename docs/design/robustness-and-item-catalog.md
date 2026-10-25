# Robustness ("crash-proof") and the item catalog: design (2026-10-25)

Luis asked two things: how to make the companion crash-proof, and how it can use any weapon or item without being slowed down in real deployment.

## 1. Crash-proofing

Key fact: **`pcall` does not protect us from native crashes.** A bad argument or a game null-dereference kills the process. So robustness comes from layers.

| Layer | What | Status |
|---|---|---|
| 1. Never take known-crashing paths | Puppet lifecycle module. The puppet is never unpossessed; removal means hide plus teleport plus park its AI. One puppet per server run, reused across player sessions. Immortal (`SetIsImmortal`) so death never runs the unpossess path. | to build (`mod/body/puppet.lua`) |
| 2. Fix the root cause | The unpossess crash is `PC->LoadoutComponent` on a null PC. Experiments: before unpossess, unbind or destroy the components whose controller-changed handlers touch the loadout (PlayerEquipmentComponent, attack/loadout-delegate components), or clear `ReceiveControllerChangedDelegate`. Bisect offline: the watchdog makes crashes cheap. | next, offline |
| 3. Safe call surface | Native calls come only through a small set of wrapper functions, each verified in game once and then frozen. Prefer functions with scalar arguments. Struct and array arguments (for example `PredictDamage`'s `TArray<FTypeDamage>`) are only allowed through wrappers that build the struct the way UE4SS expects. Unverified calls run only in `*_test.lua` debug modules. | in progress |
| 4. Validate before calling | Check `IsValid`, check the class (`IsA`), check distance and range, and refuse to call methods on objects that are pending kill. Use a precondition table per wrapper. | to build |
| 5. Fail fast and recover | `tools/watchdog.ps1`: when a crash dump appears it kills and restarts the server, and it restarts a missing process. On restart the mod respawns the puppet from the persisted bot state (layer 7). | **done** (watchdog) |
| 6. Know what crashed | UE4SS dumps plus `cdb` (stack, exception), offset lookup in CXXHeaderDump, Lua breadcrumbs flushed per line. Next: auto-analyse each new dump with `cdb` into `logs/crashes.jsonl` (exception, top frames, last breadcrumb). | partly done |
| 7. Persistent bot state | The bot's gear, inventory and stats live server-side in `logs/state/bot.json` (or SQLite) and are re-applied on spawn. World backups come from `update_server.ps1`; take a snapshot before risky sessions. | to build |
| 8. Canary before live | A new native call is first run offline (no players) by the test harness, and only then promoted to the live skill registry. That is CLAUDE.md principle 3. | process |
| 9. Patch safety | After each game patch, regenerate the dump and run smoke tests. Class and offset changes show up as wrapper failures, not crashes, because of layer 4. | process (CLAUDE.md section 8) |

## 2. Item catalog: any weapon or item, used correctly, with no runtime discovery

Goal: the companion can equip any weapon or armour (picked up, given, or chosen), knows how to fight with it, and pays no lookup cost at play time.

**Build once per game build (offline), store as `data/items_<build>.json`:**
- Enumerate every `UHeldEquipmentData` (weapons and tools) and `UWearableEquipmentData` (armour). 168 and 235 were loaded at idle; the asset registry lists the rest, including unloaded ones.
- Record per item:
  - path and display name
  - category (sword, mace, greatsword, bow, staff, axe, pickaxe, torch...)
  - slot (right/left hand, head/body/legs/cape)
  - tier and stats
  - `HeldEquipmentActorClass`
  - the attack set the game uses for that category (`BP_Player_<Cat>_Attack1..N`, `PA_Attack_<Cat>`)
  - its range type (melee/ranged/magic)
- Source: UE4SS asset registry calls (`AssetRegistryHelpers` / `AssetRegistry:GetAssetsByClass`) plus property reads; the reflection dump for the field names.

**Use at runtime:**
- `equip(item_id)` loads the data asset (`StaticFindObject`, else `LoadAsset` once, then cached), spawns its `HeldEquipmentActorClass`, attaches it to `prop_r`/`prop_l`, and sets the replicated slot (the method verified on 2026-10-25).
- **"Knows how to use it"** is a per-category combat profile, written once in code: melee approaches and swings with that category's attack set; bow keeps distance and fires; staff casts. The planner and controller choose a weapon by catalog stats (damage, range) for the situation.
- Picking up loot: a world drop (`RuntimeSpawnedWorldItem`) carries its item data, so map it to the catalog, then `equip` or stash it in the bot's inventory (layer 7). No player inventory component is needed.
- Preload the attack-set assets for the bot's current weapons at spawn, so the first swing has no load hitch. (Only sword attacks were loaded at idle; mace and other attack sets load on demand.)

## 3. Combat: two speeds (Luis asked whether fast combat needs constant LLM calls)

The LLM is never in the per-frame loop: model latency is 0.3–1 s and combat windows are shorter (CLAUDE.md principle 1; PUBG Ally, PIANO, GITM).

- **Reflex layer** (Lua, game tick, no LLM):
  - Swing on cooldown along the weapon's attack chain, which comes from the catalog (`attacks.*.chain`).
  - **Evade on enemy telegraph.** The server already logs `DominionAiAttackComponent: AUTH ATTACK : TELEGRAPH ... TimeUntilEvent` and `EvadeAttack: PredictPointDamage ... will receive N damage`; hook the reflected source of these.
  - Block; keep range with a bow; retarget when the target dies; drink a potion under an HP threshold; disengage when outnumbered beyond a set limit.
- **Tactics** (Controller, Haiku): called only on meaningful change: fight start, a new enemy, low HP (own or Luis's), target down, tactic failed.
  - Each call gets a fresh compact state snapshot plus the recent important events.
  - It sets the reflex parameters (focus target, weapon, stance, retreat threshold).
- **Plans** (Planner, Sonnet): minutes-scale goals.
- **Rate limit:** coalesce events, at most one Controller call every ~2 s. Worst case about 1,800 calls/h, roughly $1.25/h on Haiku 5.5 ($0.10/$0.50 per M tokens). A realistic mixed session costs $0.50–2/h including the Planner.

## 4. Spells and weakness-aware weapon choice (Luis's examples, 2026-10-25)
Luis relies on spells: **a shield spell**, and **wind jump**, whose landing stuns enemies and works well against Kalphites. He wants the bot to switch to the best weapon in its slots for the enemy, exploiting weaknesses.
- **Spells are player actions** (e.g. `PA_Spell_Sword_JumpAttack`, magic collections on staves, `BP_SMBG_*` spell modules). Cast them through the same server-side action path as melee (`BP_PerformAttack`-style), to be confirmed by research.
  - Catalog each spell: cost, cooldown, effect (stun, shield), area, timing.
  - **Reflex rules:**
    - Shield on an incoming big telegraph or low HP.
    - Wind-jump into clusters (3+ enemies in radius, especially Kalphites), then swing during the stun.
  - The Controller sets spell tactics and honours Luis's instructions ("save shield for the boss").
- **Enemy table** `data/enemies_<build>.json`, generated like the item catalog: per enemy class, its damage-type resistances and weaknesses, HP, notable attacks and telegraph timings.
  - **Weapon choice:** for each weapon in the bot's slots, score = expected damage × the target's multiplier for the weapon's damage types. Swap on target change when the gain beats a threshold, which avoids flip-flopping.
  - The Controller sees the same table, so it can explain choices in chat and override them.

## 5. Prior art check (web, 2026-10-25), done after Luis asked "has this been done already?"
- **Standard industry pattern:** a hybrid. A **behaviour tree (BT) orchestrates** execution and sequencing; **utility AI scores the options** (which weapon, which target, which spell), because BT selectors are poor at weighing options; GOAP is reserved for multi-step goals. ([UtilityAI repo](https://github.com/WarreVannTittelboom/UtilityAI), [gamedev.net thread](https://gamedev.net/forums/topic/674191-ai-for-an-active-time-based-combat-system), [Unity utility framework](https://discussions.unity.com/t/released-utility-intelligence-go-v3-utility-ai-framework/940124))
- **LLM plus game AI:** the 2026 mapping review of hybrid BT–LLM architectures for latency-sensitive game agents finds designs keep **LLM deliberation separate from symbolic execution**, with BTs, utility systems or FSMs doing real-time control ([Zenodo review](https://zenodo.org/records/23222129)). This matches our two-speed design.
  - PORTAL has LLMs generate BTs in a DSL for 3D games ([arXiv 2503.13356](https://arxiv.org/pdf/2503.13356)).
  - Related: LLM-generated BTs for NPCs ([ACM](https://dl.acm.org/doi/10.1145/3696630.3728553)); LLM-guided RL for combat NPCs ([arXiv 2609.02931](https://arxiv.org/pdf/2609.02931)).
- **Mineflayer (the Minecraft bot ecosystem Mindcraft builds on):**
  - Combat is plugins, not LLM: [mineflayer-pvp](https://www.npmjs.com/package/mineflayer-pvp) (attack loop over a pathfinder).
  - [mineflayer-custom-pvp](https://unpkg.com/@nxg-org/mineflayer-custom-pvp@1.7.16/README.md) adds criticals, strafing, shield handling, a bow module, and **switching to an axe when the opponent shields**: rule-based weapon switching.
  - [mineflayer-tool](https://github.com/TheDudeFromCI/mineflayer-tool) does best-tool selection.
  - So the LLM agents above them only pick goals.
- **Don't hand-roll the BT:** pure-Lua BT libraries exist:
  - [behaviour_tree on LuaRocks](https://luarocks.org/modules/timanema/behaviour_tree) (supports Lua 5.1–5.4)
  - [behavior3lua](https://gittrend.io/repo/zhandouxiaojiji/behavior3lua), the most used, with a visual editor ecosystem
  - [beehive.lua](https://github.com/drhayes/beehive.lua) (MIT, small)
  - Pick one for the reflex layer instead of ad-hoc loops.
- **Revised design:**
  - The reflex layer = a vendored Lua BT (execution: approach, combo, evade-on-telegraph, cast).
  - Utility scoring nodes choose the weapon (damage × the enemy weakness table), the target and the spell (wind jump when the cluster count is at least N).
  - The LLM sets goals and weights ("focus archers", "save shield"), not actions.
- Still to research: OSRS bot frameworks (RuneLite/DreamBot scripts do gear and prayer switching by monster weakness). Possibly reusable data on RuneScape monster weaknesses, though Dragonwilds' stats are its own.

## 6. Luis's spell kit (his words, 2026-10-25). The bot should use these and mirror his stats and unlocks
- **Tempest Shield:** the defensive shield.
- **Windstep:** AoE stun on landing; "fantastic" against Kalphites.
- **Melee weapon enchants:** change or boost the weapon's damage type (pair with the enemy weakness table).
- **Spectral Arrows:** ranged.
- **Requirement:** the bot mirrors Luis's stats and unlocks, so it has the same spells. Research is in `docs/research/2026-10-25-spells-and-weaknesses.md` section 5.
- **Correction (Luis):** those were only examples. The bot should have **all spells**, including utility ones such as **Magical Mending**: Luis drops damaged gear on the floor and the bot repairs it. The spell catalog must cover every spell; skills are added and verified one at a time.

## 7. Luis's next requirements (2026-10-25)
- **Overhead name "Claude":** the nameplate (`UPlayerNameplateWidget.PlayerNameTextBlock`, client-side) shows "Character Name Here" because the puppet has no PlayerState or character identity. Identity agent investigating: PlayerState via bWantsPlayerState, SetPlayerName, and linking the OwnerGuid to the registered "Claude" display-name entry.
- **Persistent inventory:** today only worn and held gear persists (`logs/state/bot_state.json`). Needed: a server-side bot inventory store (items and counts, persisted), used by the pickup, drop, give, craft and loot skills.
- **Pick up items:** walk to a `RuntimeSpawnedWorldItem` or gatherable, remove the world item, add it to the bot store (pickup hook path in DISCOVERIES "Phase 2 hooks").
- **Drop items:** spawn a `RuntimeSpawnedWorldItem` from the item data at the bot's feet (and support "give" by dropping near Luis or magnetising, `BP_MagnetizeToPlayer`).
- **Lodestone teleport:** a travel skill that teleports to lodestones (lodestone actors and positions; Luis's unlocked lodestones; TeleportationSubsystem / K2_TeleportTo).
- **Sequencing:** these go after the combat and architecture agents land (they share mod/body files). The services are mod/body/inventory.lua and mod/body/travel.lua, registered via the ARCHITECTURE.md conventions.

## 8. Phase 8 target task (Luis, 2026-10-25): "chop trees until you have 4 stacks of oak logs, then drop them at my feet"
- Steps: find oak trees (nearest first, skip stumps), chop (axe swing), the tree falls, chop the felled trunk into logs, pick up the dropped logs into the bot inventory store, count against 4 × the stack size (verified from the store), repeat (widen the search radius), walk to Luis, drop the logs.
- Brain: the Planner decomposes and replans; the Executor verifies each step against game state; the agent asks for help when stuck (no trees, path blocked).
- Body skills required: inventory store, pick up, drop, gather/woodcutting. Research: `docs/research/2026-10-25-woodcutting-loop.md`.
- This is the **Phase 8 gate** candidate, including a deliberate failure (no trees in range) to check that it replans or asks for help.

## 9. When to cast which spell (2026-10-25)
- Gathering spells Luis wants used in the woodcutting task: **Astral Projection, Trunk Totem, Splinter**.
- **The spell catalog** (`data/spells_<build>.json`) records per spell: role tag (combat_defence / combat_cc / combat_damage / weapon_buff / gathering_buff / gathering_aoe / scouting / repair / travel), preconditions, rune cost, cooldown, and a one-line "use when" text for the LLM.
- **Reflex layer:** utility scoring. Each castable spell is scored against the situation (chopping with an axe, enemy cluster, incoming telegraph, damaged item); the best spell above a threshold is cast. No LLM involved.
- **Controller:** sees the short list of castable spells; follows Luis's instructions; stores habits in notes via `remember`.
- **Rune policy** (`spells.cost_policy`): free | budget (the bot's own runes in its inventory store) | mirror (only Luis's unlocked spells). Proposed default: mirror + budget, with free as a debug toggle. **Awaiting Luis's choice.**

## 10. Learning on the go: standing orders become reflex rules (Luis, 2026-10-25)
- Model calls are stateless. Memory lives in our files: `notes.json` via `remember()`, the task tree, and the progress log. Relevant parts go into each call (CLAUDE.md principle 4).
- "Claude, every time it does X, do Y" (e.g. during a boss fight):
  - The Controller converts it into a structured **reflex rule** via a tool `set_reflex_rule(trigger, action, scope)`.
  - The body executes the rule at tick speed. It persists per enemy type, so it is reused at the next encounter.
- **Triggers** = only what the body can sense: enemy telegraph or attack id (`DominionAiAttackComponent` TELEGRAPH), enemy HP %, enemy count/cluster, own or Luis's HP %, enemy stunned, buff/debuff tags, spell cooldown ready.
- **Actions:** evade, block, cast <spell> (with target mode), switch weapon, retreat to Luis, focus target, use item.
- If a requested trigger isn't sensable, the Controller says so.
- Tasks: P7.R1 (body: rule engine + trigger sensors), P7.R2 (brain: `set_reflex_rule`, `list_rules`, `clear_rule` tools, per-enemy persistence).

## 11. Game patches: delta pipeline
- Update via SteamCMD; regenerate the reflection dump.
- **Dump diff** (new / removed / changed classes, functions, properties) flags breakage of anything we call or hook.
- **Catalog rebuild and diff** (items / spells / enemies). New weapons, bosses and items are mostly auto-supported via the catalogs; new spells get LLM-drafted role tags for review.
- **Smoke tests**, then a delta report listing what is auto-supported, what needs review and what is broken.
- Built by the patch-pipeline agent: `tools/patch_pipeline.py` and `docs/RUNBOOK-patch.md`.

## 12. Equip rule (Luis, 2026-10-25): the bot equips only what is in its inventory, like a normal player
- `equip` must check the bot inventory store and refuse items the bot doesn't own (`reason: not_in_inventory`). Gear enters the inventory only through pickup, Luis giving it, or crafting. A debug override requires an explicit flag and is never used by the brain.
- **There is no generic fallback** (removed 2026-10-25): if the item's exact held-actor class can't be resolved (data-asset soft pointer via LoadAsset, then the catalog `held_class`), equip fails instead of spawning `BP_HeldEquipmentBase_C`, which rendered a blank placeholder sword.

## 13. Item instances, not item types (Luis, 2026-10-25)
- Luis's Skullsplitter is **ascended level 6**. Upgrade level, ascension, enchants and durability live on the **item instance** (`UItem` / `HeldEquipmentItem` in the PlayerController's inventory), not on the `UHeldEquipmentData` asset.
- The bot's held actors are spawned from the data asset only (`HeldEquipmentItem` = nil), so they very likely behave as **base, unupgraded** items. That is fine for visuals and wrong for "acts like a player".
- **The bot inventory store must hold instances:** `{item_data_path, count, level, ascension, enchant, durability, perks...}`. Equip must attach a matching `HeldEquipmentItem` (built from the stored instance state, or copied from an item Luis hands over) so server damage reflects the real item.
- Research needed: the `UItem` / `HeldEquipmentItem` property layout and how upgrade level feeds damage (power level / ascension multipliers). Can the server construct a `UItem` for the puppet safely (object, not struct)?

## 14. Capabilities should get cheaper over time (Luis's principle, 2026-10-25)
"I don't mind spending a while learning how to get it to chop a tree … AS LONG AS it is centralised and /simplified, so 'add mining' takes a fraction of the time, until adding functionality is easy, or something it could figure out on the fly."
- Every new capability must leave behind **shared services**:
  - `sense`: census and filters
  - `watch`: generic state watcher, for learning and verification
  - `hitcheck`: whether a hit registered and why not
  - `tool chains`: from the catalog
  - `collect + verify`: via inventory
  - plus **data profiles** (resources, spells, enemies, items)
- A new gatherable or mechanic = census → watch one instance (by the bot itself or Luis) → write a profile → the shared loop runs it.
- End state: the brain can propose a profile from watch data for an unknown thing, then test it.
- After each wave, run a `/simplify` pass to extract and dedupe, and update the ARCHITECTURE.md recipes ("How to add a new gatherable / spell / enemy / skill in N steps").

## 15. Per-world memory and named places (Luis, 2026-10-25)
- "Our farm is at lodestone X in Fellhollow → 'go to the farm and farm desert weed'".
- **Per-world memory:** key `notes.json` (and rules, task tree) by the world's **`WorldSaveGuid`**, which the server advertises in session settings (CompanionDev = EE0ADF284F2591BC344C6AA8A1FE985C). Storage: `logs/state/worlds/<guid>/`. Facts never leak between worlds.
- **Named places:** `remember_place(name, at="here"|"luis"|coords, notes)` stores {position, region (from game map-region data), nearest lodestone, notes}. The Controller exposes these places to the Planner.
- **Travel to a place:** nearest unlocked lodestone teleport (travel skill P7.T1), then go_to. The places list goes into bounded context (CLAUDE.md principle 4).
- Also per world: preferences, standing reflex rules per enemy class, known stations, chests and beds.

## 16. Farming (planned after gather + inventory + spells)
- Steps: plot state → plant → tend/water (spells?) → grow → harvest → replant.
- Built on the shared services:
  - `sense`: plots and growth state
  - `watch`: record one cycle (Luis or self-test)
  - crop **profiles**: seed, plot, stages, helpful spells, harvest action, yield
  - primitives: interact, plant, cast on plot, harvest, collect
  - the Planner composes "farm X at the farm".
- Expect most of it to be reuse by then (section 14).
