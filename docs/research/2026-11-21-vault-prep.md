# Vault prep: what a strong player knows before a Dragonkin vault, and what Claude can reach (2026-11-21)

Offline research. Nothing was run against the server, the client or the brain, and no model was called. The `Knowledge.lookup` runs were offline, on the index the live brain uses (`data/wiki/knowledge.sqlite`, game build 26670300, wiki mirror of 2026-10-25). This file is the only one edited.

This note is **knowledge for him to consult and gaps in what he can see**. It is not a recipe: nothing here goes into a prompt as an instruction, and nothing here picks his approach.

## Need

The capstone (`docs/GOAL-2026-11-17-long-jobs.md` section 4, Rung 6) is "from one ask he prepares for a vault, clears it and kills its boss". It starts with Crasorak Kara. The live probe of 2026-11-19 (DISCOVERIES "Inside Crasorak Kara") saw a Hulk at 10 m on arrival, the Vault Overlord (1300 HP), and 26 trap rows. The question is what a good player knows and does to survive that, and which of those facts reach Claude today through lookup, perception and the fight odds.

## Searched

- **Local wiki mirror** `data/wiki/pages/*.json` (3802 pages): titles and full text matching vault, kara, trap, whetstone, tempest, enchant, bolt, oil, focus, dodge, invulnerab, burning, power level, stamina, and the vault, guardian, trap and buff pages listed under Found.
- **Game data:** `data/items_26670300.json` (471 equipment rows only), `data/recipes_26670300.json` (1120 items, 1271 recipes), `data/spells_26161880.json` (the newest spells file), `data/spell_effects.json`, and the `dumps/26670300` header dump (`AAnimatingTrap`, `ASwitchableTrap`, `FTrapDamage`, `UTrapTimelineEventData`, `GE_Damage_FireTraps`).
- **Code:** `brain/knowledge.py` (lookup, walkthrough), `brain/situation.py` (odds notes 191-245, Hazards line 812-840, status and enchant lines), `client_mod/scripts/combat.lua` (`castable_prep` 5778, `loadout_capability`, `boss_prepared`, `prepared_odds`), `client_mod/scripts/sense.lua` (`describe_trap` 993, the hazards pass 1191), `hazard_profiles.lua`, `ground_hazards.lua`, `creature_wiki.lua`, `boss_profiles.lua`, `inventory.lua` `M.use`, `mod/body/spells.lua` (the `use_when` texts), and `logs/evals/vault_probe/20261119-063427_enter.json` (the trap rows).
- **Web** (2026-11-21):
  - the live wiki (Whetstone, Tempest Shield, Dodge, Dodging, Stamina, Fire Trap, Burning, Antifire, Fire Jet, Spike Trap, Vault Overlord, Vault Guardian Sentinel, Crasorak Kara, Thishepen Kara, Dragonkin Vault);
  - the official 1.0 and 1.0.2 news posts;
  - Fextralife, MetaForge, metabot.gg, Game8, a Steam guide;
  - Reddit r/RSDragonwilds (search snippets only: the pages answer 403);
  - three YouTube videos (descriptions and transcripts as far as they could be fetched).
- **Found nothing for:**
  - trap damage per hit, fire-trap cycle timing or dodge invulnerability-frame length, in any source;
  - Overlord damage per hit from players (the game's own attack data has it, below);
  - wiki pages for "Magic Bolt" traps, "Energy Barrier", Uzzer Kara or Manafem Kara;
  - any "/Strategies" page for a vault guardian;
  - Enchant Weapon: Earth on the wiki (it is in the 1.0.2 notes only).
  - Not fetched: MetaForge vault guides, GameRant, TheGamer, PCGamesN, Reddit thread bodies, and the Nexus "Vault Traps" mod page (403).

## Found

### 1. What decides survival, ranked

Ranked by how much each decides whether a player at the vault's power level dies. A number in brackets is the source's own.

**1. Reading the guardians' and the boss's moves (block, parry or dodge per attack).** Hulk and Overlord share one moveset ([Vault Guardian Hulk](https://dragonwilds.runescape.wiki/w/Vault_Guardian_Hulk), [Vault Overlord](https://dragonwilds.runescape.wiki/w/Vault_Overlord)):
- **Rapid spin.** It closes the distance and "is designed to wear down stamina". Dodge it, because blocking drains stamina fast. A video says the spin hits up to 3 times ([YouTube 0p0xOZh4nYw](https://www.youtube.com/watch?v=0p0xOZh4nYw)).
- **Single fist slam.** It is easily blocked, and a parry makes the Overlord collapse.
- **Double-fisted slam.** It breaks a block and stuns the player. It also stuns the Overlord whether it hits or not, so the answer is to dodge and then punish.
- **The game's own attack data for the Overlord** (base damage before armour, `data/bestiary.json` via the lookup card): Slam 43, Slam Retaliate 43, Smash left and right 30, Swipe left and right 30, Arm Throw 26, Spin 24. Player health is 100 plus sanguine urns ([Combat](https://dragonwilds.runescape.wiki/w/Combat)). So one unblocked slam takes about 40 % of a fresh character's health.
- **Sentinels attack at range** ([Vault Guardian Sentinel](https://dragonwilds.runescape.wiki/w/Vault_Guardian_Sentinel)):
  - a Magic Missile that "can track the player slightly";
  - a projectile that travels underground and erupts as spikes beneath the player, which is dodged.
  - The walkthrough's answer is cover with your own ranged attacks, or holding up a shield and countering ([Crasorak Kara](https://dragonwilds.runescape.wiki/w/Crasorak_Kara)).
- **Parry:** unlocked at Attack 5. It staggers most enemies about 3 s, and recovery takes 0.55 s ([Parry](https://dragonwilds.runescape.wiki/w/Parry)). Since 1.0 a parry restores 50 % of max stamina ([1.0 notes](https://dragonwilds.runescape.com/news/launch)).

**2. Tempest Shield cast before each engagement.**
- **Numbers:** Attack 11, 15 Air runes, 45 s cooldown, about 1 minute; the upgrade at Attack 65 adds 30 s ([Tempest Shield](https://dragonwilds.runescape.wiki/w/Tempest_Shield), [Tempest Shield Upgrade](https://dragonwilds.runescape.wiki/w/Tempest_Shield_Upgrade), [Fextralife](https://runescapedragonwilds.wiki.fextralife.com/Tempest_Shield)). The game data agrees: `USD_TempestShield`, Air 15, cooldown 45 s, effect seen live (`data/spell_effects.json`).
- **What it does (wiki):**
  - it "prevents all damage **while blocking**", even barehanded;
  - when it ends with the block raised, a wind burst knocks nearby foes down;
  - "always cast it before an encounter (as there is usually scarcely time to cast it once already in battle)".
- **Game data disagrees on "all damage":** `combat.lua` `tempest_hp` reads the shield as a health pool, 50 + 7.5 x Attack level from `GE_TempestShield`. That is 132 at Attack 11, about three Overlord slams. Not verified live.
- **How players rate it:** Reddit calls it "the greatest spell in the game" but says it "can expire at bad times". Another player names "Tempest shield + enchant weapon (air)" as what carries them solo (snippets: [1](https://www.reddit.com/r/RSDragonwilds/comments/1xcjxjt/tempest_shield_is_the_greatest_spell_in_the_game), [2](https://www.reddit.com/r/RSDragonwilds/comments/1wupo05/question_for_the_solo_players)). The hard-mode Crasorak video recasts it from behind a pillar as soon as it expires.
- The words "an absolute must" were not found in any source read.

**3. Fight them one at a time.**
- The first big room has three Hulks. The walkthrough says to use the stairs to range them or to hold a chokepoint, and to cast Tempest Shield and Enchant Weapon: Fire before entering ([Crasorak Kara](https://dragonwilds.runescape.wiki/w/Crasorak_Kara)).
- Spike traps hurt monsters too, and players use them: "you can use the spikes to dispatch it" ([Spike Trap](https://dragonwilds.runescape.wiki/w/Spike_Trap)). A Reddit snippet says guardians are briefly stunned by spikes ([Reddit](https://www.reddit.com/r/RSDragonwilds/comments/1s5bob4/noob_i_feel_squishy)).
- The boss room's pillars break line of sight. On high ground out of reach, the Overlord uses a fire attack to force you down ([YouTube 0p0xOZh4nYw](https://www.youtube.com/watch?v=0p0xOZh4nYw)).

**4. Traps.**
- **Fire traps in halls:** three in the south hall, two on the optional path ([Crasorak Kara](https://dragonwilds.runescape.wiki/w/Crasorak_Kara)). The walkthrough says "time dodge rolls past each set ... dodge rolls will get you safely past all of them". The two videos disagree on how:
  - "no need to stop and time your dodges ... quickly dodge roll through all three" ([0p0xOZh4nYw](https://www.youtube.com/watch?v=0p0xOZh4nYw));
  - "wait for the flames to drop, then dodge roll straight through" ([GNlzRQHmZhA](https://www.youtube.com/watch?v=GNlzRQHmZhA)).
- **Burning (the fire traps' effect):**
  - The current wiki gives 8 HP/s for 6 s, 48 in all. Antifire prevents it, and dodge rolling or entering water shortens it ([Burning](https://dragonwilds.runescape.wiki/w/Burning)).
  - The Fire Trap page still says 5 HP/s for about 15 s and mentions Lifeward. Lifeward has been removed from the game, so that page is stale ([Fire Trap](https://dragonwilds.runescape.wiki/w/Fire_Trap), [Lifeward](https://dragonwilds.runescape.wiki/w/Lifeward)).
  - Antifire potion: removes Burning stacks and gives 33 % resistance to buildup, 300 s (super: 600 s) ([Antifire](https://dragonwilds.runescape.wiki/w/Antifire)). Its recipe needs Blue Dragon Scale Dust, so it is not reachable at Crasorak's level.
- **Spike floors:**
  - Tiles glow yellow briefly before the spikes deploy. Standing on them hurts repeatedly. Windstep or spaced, timed dodge rolls get past ([Spike Trap](https://dragonwilds.runescape.wiki/w/Spike_Trap)).
  - At Crasorak the spikes are laid out in a diamond, "thinnest" against the walls ([Crasorak Kara](https://dragonwilds.runescape.wiki/w/Crasorak_Kara)).
  - The game names `GE_Damage_StaticSpikes` and `GE_Slow_StaticSpikes`, so spikes also slow (`docs/research/2026-11-17-vault-reads.md` 1.2).
- **Other vaults' traps:**
  - Spear traps: 7-10 damage, rhythmic, 10 m from the wall ([Spear Trap](https://dragonwilds.runescape.wiki/w/Spear_Trap)).
  - Shock ray (Kalistrakthen Kara): 2 damage, and "dodging into the trap negates the damage" ([Shock Ray Trap](https://dragonwilds.runescape.wiki/w/Shock_Ray_Trap)).
  - Exploding plants (Skeklac, Kletterbuja): 30 damage within 2 m; shoot them from range first ([Exploding Plant Trap](https://dragonwilds.runescape.wiki/w/Exploding_Plant_Trap)).
  - Pressure plates and inactive guardians that wake (Kalistrakthen) ([Kalistrakthen Kara](https://dragonwilds.runescape.wiki/w/Kalistrakthen_Kara)).
  - Wither and fire jets (Vekchenven) ([Vekchenven Kara](https://dragonwilds.runescape.wiki/w/Vekchenven_Kara)).
- **Dodge invulnerability: not settled.**
  - The wiki has no number. "Dodge" redirects to the Evasion perk, and the Dodging page is a stub; a no-direction dodge is a backward jump ([Dodging](https://dragonwilds.runescape.wiki/w/Dodging)).
  - One video says a dodge negates all damage ([y4h2-tocOI0](https://www.youtube.com/watch?v=y4h2-tocOI0)).
  - A dodge guide says ranged hits can land in the first frames, chained rolls cover continuously, acid pools hurt through a roll, and you cannot dodge at all when overburdened ([rzqjiWhx5o0](https://www.youtube.com/watch?v=rzqjiWhx5o0)).
  - The Shock Ray page is the only wiki statement that a dodge negates trap damage.
  - Surge (Magic 11, 10 Law + 10 Astral, 45 s): three longer dodges of 8 m that "evade longer", named for "monsters and vault traps" ([Surge](https://dragonwilds.runescape.wiki/w/Surge)).
- **Stamina:** a dodge costs 20, a jump 10, a blocked hit with a shield 17; holding block costs nothing. Regeneration starts after 3 s and runs 0.75/s at 0 hydration up to 6/s at 100 ([Stamina](https://dragonwilds.runescape.wiki/w/Stamina)).

**5. Armour power level against the vault's power level.**
- **Player power level** is the average of the worn armour's power levels, rounded down ([Power level](https://dragonwilds.runescape.wiki/w/Power_level)).
- **Monster health scales** with the region's power level.
- **Vault power levels:** Crasorak, Thishepen and Vertentis 2; Takla and Kletterbuja 3; Skeklac and Chaktan 4; Kalistrakthen, Skekven and Vekchenven 5; Uzzer and Manafem 7 ([Dragonkin Vault](https://dragonwilds.runescape.wiki/w/Dragonkin_Vault)).
- **A Steam guide's armour targets:**
  - Crasorak 1-2;
  - Thishepen and Vertentis 2;
  - Takla 2-3, Kletterbuja 3;
  - Skeklac 3-4, Chaktan 4;
  - Kalistrakthen and Vekchenven 4-5, Skekven 5;
  - Uzzer 6-7, Manafem 7.
  - It warns that enemies hit noticeably harder from vault level 3 on ([Steam guide 3465679303](https://steamcommunity.com/sharedfiles/filedetails/?id=3465679303)).
- **The hard-mode video** says the Overlord "can literally one-shot you" there.

**6. Damage type against weakness and immunity.**
- **Every vault guardian is immune to Poison, Bleed and Burning.** So weapon poison, barbs, fire arrows' burn and Enchant Fire's burn-on-crit do nothing to them.
- **Hulk and Sentinel are weak to Crush.**
- **The Crasorak Overlord (power level 2) has weakness "None".** Only the Skekven one (power level 5) is weak to Crush. The live infobox shows both values ([Vault Overlord](https://dragonwilds.runescape.wiki/w/Vault_Overlord)). One video calls it weak to magic and crush (unsourced).
- **Incinerator (Takla), Pyroclast (Chaktan) and Corruptor (Skeklac)** are weak to Water and resist Fire ([Vault Incinerator](https://dragonwilds.runescape.wiki/w/Vault_Incinerator), [Vault Pyroclast](https://dragonwilds.runescape.wiki/w/Vault_Pyroclast), [Vault Corruptor](https://dragonwilds.runescape.wiki/w/Vault_Corruptor)). Skeklac also asks for antipoison ([Skeklac Kara](https://dragonwilds.runescape.wiki/w/Skeklac_Kara)).
- **No wiki weakness** for the Archon (Thishepen, 3100 HP, ranged) or the Striker (Kalistrakthen, 3738 HP, melee and shock).
- **Crush weapons** are fists, clubs, maces, warhammers and mauls ([Crush](https://dragonwilds.runescape.wiki/w/Crush)). The hard-mode video brings a bone club for the guardians and a dagger for the rats.

**7. Damage buffs that stack.**
- **Melee:**
  - **Whetstone:** a 15 % damage multiplier on the held melee weapon for 10 minutes. It stacks with Enchant Weapon. Unlocked at Attack 40 (live wiki and MetaForge; the Combat page says 30). Made from 5 Granite and 10 Stone at the Blacksmith's Bench ([Whetstone](https://dragonwilds.runescape.wiki/w/Whetstone), [MetaForge](https://metaforge.app/runescape-dragonwilds/database/consumables/whetstone)). No source says "+2", so the brief's "+2 for 10 minutes" is not supported.
  - **Enchant Weapon (Fire, Attack 20 / Air, Attack 30 / Water, Attack 50):** +33 % of weapon damage as that element, on every target, for 5 minutes. They do not stack with each other but do stack with whetstones and attack potions. Their effects:
    - Fire: burn on crit (wasted on guardians);
    - Air: faster attacks;
    - Water: slow on crit.
    - The wiki says the cooldown is 90 s; the game data says 300 s ([Fire](https://dragonwilds.runescape.wiki/w/Enchant_Weapon:_Fire), [Air](https://dragonwilds.runescape.wiki/w/Enchant_Weapon:_Air), [Water](https://dragonwilds.runescape.wiki/w/Enchant_Weapon:_Water); `data/spell_effects.json`).
  - **Enchant Weapon: Earth arrived in 1.0.2, at Attack 60.** Hits build up to 3 stacks of "Armour of the Earth", each used up to reduce the next hit taken ([1.0.2 notes](https://dragonwilds.runescape.com/news/1.0.2-update)).
  - **Lesser Attack Potion:** +25 % melee crit chance for 10 min ([Lesser Attack Potion](https://dragonwilds.runescape.wiki/w/Lesser_Attack_Potion)).
- **Magic:**
  - **Magical Focus (the staff's whetstone):** +15 % staff damage for 10 min, Magic 39. Made from 1 Wild Anima and 10 Stone at the Blacksmith's Bench. It stacks with the Lesser Magic Potion's +25 % spell crit ([Magical Focus](https://dragonwilds.runescape.wiki/w/Magical_Focus), [Lesser Magic Potion](https://dragonwilds.runescape.wiki/w/Lesser_Magic_Potion)).
  - Water staves suit the Water-weak bosses. Earth staves (Magic 14, 1.0.2) deal blunt damage that staggers and area damage.
- **Ranged:**
  - **Enchanted crossbow bolts** (Ranged 35) give a 15 % chance per shot of an effect: earth damage, shock, water slow, heal 20 %, poison burst, crit for health, or armour penetration ([Enchanted Crossbow Bolts](https://dragonwilds.runescape.wiki/w/Enchanted_Crossbow_Bolts)). The poison burst is wasted on guardians.
  - **Fire oil** (Ranged 45) turns arrows into fire magic damage with 60 % burn buildup ([Fire Oil](https://dragonwilds.runescape.wiki/w/Fire_Oil)). The burn is wasted on guardians.
  - The Steam guide says to bring 300+ arrows.

**8. Healing and sustain.**
- **Every healing potion is "(Expired)" in this build's game data** (Weak, Lesser and plain Healing Potion: no station, no unlock; `data/recipes_26670300.json`). Lifeward is gone. That leaves food as the only heal.
- **Food:** the hard-mode video brings sweet veg balls (70 HP).
- **Evasive Infusion:** −33 % dodge stamina for 5 min, from Clean Water and a Small Animal Fang at a range ([Evasion](https://dragonwilds.runescape.wiki/w/Evasion)). The video calls it "absolutely amazing" against the boss.
- The Steam guide packs a stack each of food and drink, buff food, a torch, and resist food for bosses.

**9. Weight and death.**
- **A vault core weighs 50 kg** "and can easily overencumber you" ([Crasorak Kara](https://dragonwilds.runescape.wiki/w/Crasorak_Kara)). Overburdened, you cannot dodge (dodge guide video).
- **A death inside puts the grave at the outside entrance** ([Dragonkin Vault](https://dragonwilds.runescape.wiki/w/Dragonkin_Vault)). The Steam guide builds a lodestone at the entrance.

**10. Route (Crasorak).**
- The shape of the vault: the entry, a patrolling Hulk, the 3-Hulk room, the fire hall, the spike room, the 3-Sentinel room with a core, more traps, a fork, a Windstep ledge with core 2 and a shortcut lever, then the top lever, which opens the boss door. The Overlord and core 3 are behind it ([Crasorak Kara](https://dragonwilds.runescape.wiki/w/Crasorak_Kara) walkthrough).
- Facts about the place, not steps: the probe saw 3 levers and an "Energy Barrier" teleporter to `V_CrasorakKara_FinalRoom` (DISCOVERIES ~3687).

### 2. Which items exist in game data (build 26670300)

| Thing | Game data | Notes |
|---|---|---|
| Whetstone | `ITEM_Consumable_Whetstone`, class `WhetstoneItemData`, category `Item.Whetstone`; `RECIPE_Whetstone` 5 Granite + 10 Stone at ToolsMeleeBench (shown as Blacksmith's Bench); unlock bundle empty | No magnitude or duration in our data. `USD_Whetstone` is a montage-only spell (spell_effects: n/a) |
| Magical Focus | `ITEM_Consumable_MagicFocus`, also `WhetstoneItemData`; `RECIPE_MagicFocus` 1 Wild Anima + 10 Stone | Same family. Weapon Barbs and Weapon Poison are `Item.Whetstone` too (`mod/body/recipe_data.lua` 678-686) |
| Enchanted bolts | 7 recipes at FletchingBenchv2, 33 bolts + gem + runes, unlock "SKILL LEVEL 35[ Ranged ]": Bronze (Opal, Air), Iron (Jade, Water), Blurite (Jade, Earth), Steel (Red Topaz, Ectoplasm), Mithril (Sapphire, Nature, Air), Adamant (Ruby, Fire), Rune (Diamond, Air, Astral) | Present. No enchanted arrows |
| Oils | Fire Oil (Naphtha + Coarse Thread; also `ITEM_Throwable_FireOil`), Sacred Oil, Demonic Oil | No weapon oil like a whetstone |
| Potions | Lesser Attack, Lesser Magic, Antifire, Super Antifire, Antipoison tiers, Stamina Potion, Focused/Super Focused skill potions | Healing potions are all "(Expired)" with no station |
| Infusions | Ferocious (attack stamina), Evasive (dodge), Arcane, Relentless, Fleet-Footed, and Cooling variants | Present |
| Enchant Weapon: Earth | `USD_EnchantWeapon_Earth` exists, `status n/a` "no perk unlocks it" | Our spells file is **build 26161880**. 1.0.2 (Nov 2026) made it Attack 60. Build 26670300 (patched 2026-11-18) is probably 1.0.2, but `spells_26670300.json` was never written, so the lookup's spell and perk cards may be two builds stale (unverified) |
| Trap actors | Not in any data file. Dump 26670300: `AAnimatingTrap` has `UserReadableName`, `TrapDamage` {DamageAmount, DamageClass, DamageTypes, DamageForce}, `TelegraphTimeOffset`, `TrapTimelineEventData` (`TrapTimelineLength`, events with `EventTime`/`DeactivationTime`), `CurrentTrapAnimationTime`, `TrapTimelinePlayRate`, `TrapTimelineOffset`, `bSyncWithWorldTime`. Effects `GE_Damage_FireTraps`, `GE_AddBurn_FireTraps` | All are property reads. Classes in Crasorak: `BP_Trap_Magic_Bolt_v1_C` (9 rows) and `BP_DEPRECATED_Trap_Spike_v2_C` (17 rows), whose id prefix is still `BP_Trap_Spike_v2_C`. That the "Magic Bolt" trap is the wiki's fire trap is an inference: the wiki's fire traps shoot "a fireball or blast", metabot calls Crasorak's 15 traps "magic bolt traps" |

Wiki but not game data: nothing missing among the asked items. Missing the other way: our spells catalog has no Earth magic (1.0.2).

### 3. How each fact reaches him today

**Lookup** (offline, `Knowledge.lookup`; script and outputs in the session scratchpad: `vault_lookups.py`, `vault_lookups.json`, `vault_lookups2.json`):

| Ask | What comes back | Verdict |
|---|---|---|
| "Vault Overlord", "how to beat vault overlord" | The bestiary card: health 1300, "Weak to Crush (level 5)", immunities, the three moves with the block, parry and dodge advice, game attack damages; the wiki infobox | **Reached** (fact 1, 6) |
| "vault guardian sentinel", "vault guardian hulk weakness" | Cards with the moves, Crush, immunities | Reached |
| "Crasorak Kara", "... traps", "... sentinels", "... fire traps dodge", "... hulks tempest shield" | The bestiary vault card (power level, enemies, boss, levers, chests), the wiki lead, and the empty "Location" map section. **None returns a Walkthrough section** | **Not reached**: 0 of 6 walkthrough tips in 7 asks |
| "Crasorak Kara walkthrough" | The third Walkthrough section only (the Overlord: "buff up ... save energy to block or dodge") | 1 of 6 tips. The tips on fire-trap rolls, Tempest and Fire before the Hulks, spikes along the walls, and Sentinel cover sit in sections 1 and 2, which share the heading "Walkthrough" and lose the two-per-page cap to the lead and the map stub |
| "whetstone" | Game item card (recipe), **then the spell card "Internal spell data ... do not use"**, then the wiki (15 %, 10 min, stacks) | The fact is reached, beside a card that reads as "do not use a whetstone" |
| "Tempest Shield" | Game card: "Block all damage for about a minute ... **Save it for bosses if Luis asks**." Wiki: "prevents all damage while blocking ... cast before" | Reached, but the game card's `use_when` (`mod/body/spells.lua` l. 91) is wrong ("all damage" without blocking) and carries an old instruction |
| "fire enchant", "enchant weapon fire" | Game card: "use against **Fire-weak enemies such as goblins**"; wiki: +33 % on all hits | Card text (`spells.lua` l. 101) steers the enchant to Fire-weak targets only. The wiki's +33 % applies to every target |
| "magical focus" | Game item + wiki (15 %, 10 min, Magic 39) + a "do not use" spell card | Reached, the same caveat |
| "enchanted bolts", "lesser attack potion", "antifire potion", "evasive infusion", "Surge" | Correct cards | Reached |
| "fire trap", "spike trap", "burning", "parry" | The wiki pages (the stale Fire Trap numbers; Burning's current numbers) | Reached; the two Burning numbers disagree and both come back |
| "vault fire jet" | The Fire Jet stub; the game tier gives Fire Spirit and Fire Oil (noise) | Weak |
| **"Trap Magic Bolt v1"** (what his Hazards line will say) | Bone, Blurite and Rune Bolt cards, the Weapons page | **Not reached**: the name he sees leads nowhere |
| "DEPRECATED Trap Spike v2" | Spike Trap | Reached by luck |
| "dodge roll", "dodging" | Evasion, Bed Roll; KotHaar pages | No dodge facts (none on the wiki either) |
| "Magic Bolt", "energy barrier" | Unrelated | Nothing |
| "Velgar strategies" | Velgar/Strategies lead and Basic Preset | Strategy pages reach when the title is named |

**Perception of traps.**
- `sense.lua` lists every `SwitchableTrap` within the census radius as a `hazards` row, and `situation.hazards` puts it on the Hazards line. The 2026-11-19 probe read 26 such rows.
- **The rows give only position and a name, and the name is the class word:** "Trap Magic Bolt v1", "DEPRECATED Trap Spike v2". `parts` and `active_parts` did not read (no `TrapBehaviourModules`). Whether `UserReadableName` read at all or `clean_class` filled it is unknown, since both give the same text.
- **No damage, no damage type, no cycle or phase, and no extent** is read, though the dump shows all are properties.
- `hazard_profiles.lua` and `ground_hazards.lua` have no trap profile, so walks never route round a trap and `move.lua`'s zone verdict never weighs one.
- A trap's damage would arrive afterwards as a vitals `damage` row. No trap instigator has been seen yet.

**The fight odds** (`combat.lua` `loadout_capability`, `prepared_odds`, `boss_prepared`; shown by `situation._creature_note` as "odds prepared: ... with ..."):
- **Counted:**
  - the best carried weapon against the known affinities;
  - Enchant Weapon ×1.5, **only when the target is known weak to that element**;
  - Tempest Shield as a 50 + 7.5 × Attack health pool;
  - healing food;
  - poison resistance;
  - a breath-blocking shield.
- **Not counted:**
  - the whetstone's 15 %, the Magical Focus's 15 %, and attack or magic potions' crit;
  - an enchant's +33 % against a target that is not weak to it, which is every Crasorak guardian (Crush-weak) and the Overlord;
  - Evasive Infusion;
  - blocking, parrying and dodging, and armour (the function says so).
- `castable_prep` checks only `USD_TempestShield` and the three Enchant spells. It has no consumable buffs, and Surge and Earth are absent.
- **The Overlord, Archon and Striker are missing from `creature_wiki.lua`.** Hulk, Sentinel, Corruptor, Incinerator and Pyroclast are there. So the Overlord's immunities and level-dependent weakness do not reach the odds or `combat_brief`. The bestiary lookup card has them.
- **If the game flags the Overlord `bIsBoss`** (unknown, capstone A5), `boss_prepared` uses `boss_profiles.default`. That default is Velgar-shaped: 4 windows, 3 flights of 20 s with meteor damage 2/s, poison priors. The Overlord does not fly.

**Own state.**
- His power level is on the "You" line (`situation.py` 1294) and each creature's power level on its row. So "armour level against the vault" is visible once inside. Before entering, it comes only from the vault card ("power level 2").
- A held enchant shows with its time left (`held_enchant`). A whetstone or focus effect has no read, and no use of one has ever been tried (`inventory.use` would press it through `HandleInternalUseItem`; `WhetstoneItemData` was never tested).

## Gaps, and the smallest structural changes

Each change is a perception, lookup or odds change. None tells him what to do. Each comes with the number it should move.

1. **Lookup returns a vault's walkthrough the way it returns a quest's.**
   - The change: extend `Knowledge.walkthrough` (today quest-only, `knowledge.py` 783) to any wiki page with "Walkthrough" sections, joined in page order. Drop "Map:"-only sections from the wiki tier, as the walkthrough already does.
   - The number: walkthrough tips reached in Crasorak asks, 1 of 6 today (above). Score it as new `lookup_vaults` cases ("how do I get past Crasorak Kara's traps", "what do I fight in Crasorak Kara"), tuned and held-out written before the result. The goal's own standard is 9 of 10 held-out.
2. **Trap rows say what a player would see.**
   - Read, as plain property reads on the trap: `TrapDamage.DamageAmount` and `DamageTypes`, `TrapTimelineEventData.TrapTimelineLength` with its events' `EventTime` and `DeactivationTime`, `CurrentTrapAnimationTime`, `TrapTimelinePlayRate` and `TrapTimelineOffset`, `TelegraphTimeOffset`.
   - Show each row as: a wiki name joined by its damage type (fire to "Fire Trap", static spikes to "Spike Trap"), damage, "fires every N s, next in M s", the area from its collision module.
   - Add a trap profile to `hazard_profiles.lua`, so the avoid-zone layer and its verdict know a trap's damage and timing.
   - It is a streamed BP class (R17): `U.prop` and re-find each tick, offline first.
   - The numbers: trap damage per crossing of the Crasorak fire hall (vitals damage rows), and deaths in the fire hall, in K step trials from a checkpoint at the hall. A first window gives the baseline, since no trap damage has been measured.
3. **The odds count what he can apply.**
   - Count carried `Item.Whetstone` consumables (whetstone ×1.15 melee, focus ×1.15 magic), an enchant's +33 % on any target, and attack and magic potions' crit, each named in "uses".
   - Use the wiki's `immune_effects` to drop burn and poison from the count.
   - Add the Overlord, Archon and Striker to `creature_wiki.lua`, with the Overlord's weakness tied to its level.
   - Give the Overlord a boss profile of its own (no flights) in place of the Velgar default.
   - The numbers: the gap between prepared `kill_s` and the measured fight time on Hulks and the Overlord (`fight_rate` already measures uptime); and in L3, how many of his choices before a vault include a buff consumable (0 by construction today, since none is ever offered).
4. **Fix the card texts that are untrue.**
   - Remove the montage-only `USD_Whetstone`, `USD_MagicFocus`, `USD_WeaponBarbs` and `USD_WeaponPoison` spell cards from the lookup index; their item cards stay.
   - Rewrite Tempest Shield's `use_when` to the game and wiki facts: protects while blocking, a shield pool, the burst at the end, 45 s.
   - Rewrite Enchant Fire's to: +33 % fire on every hit, burn on crit, guardians immune to burn.
   - Drop "Save it for bosses if Luis asks".
   - This is a fix in what he is told back (rule 10: one try per cause). The number: the lookup eval on "whetstone" and "should I enchant" cases, where the card's own words count as a miss today.
5. **Regenerate the spells catalog for 26670300** (`docs/RUNBOOK-patch.md` never wrote `spells_26670300.json`). The number: the count of spells and perks in the lookup index against the game's, and Enchant Weapon: Earth's status (n/a today).
6. **Make the whetstone's effect readable before he is offered it** (rule 4).
   - Find where the honed state lives on the held item: `MagicalHeldEquipmentEffectInfo`, as the enchant uses, or another struct. That is an offline dump search, then one live read.
   - The number: one unseen row with the log line that shows the effect and its time left.

## Limits

- Wiki pages are community-written. The Fire Trap page is stale, and the Overlord's power level 2 weakness is "None" on one field and "Crush" in the infobox's list.
- The dodge invulnerability window, the trap cycle times and trap damage are unknown from every source. Change 2 would read the last two from the game.
- The Steam guide's armour table and the videos are single sources. Reddit was read from search snippets only.
- That build 26670300 is patch 1.0.2 is an inference from dates (patched 2026-11-18; the 1.0.2 post is from November 2026).
- That `BP_Trap_Magic_Bolt_v1_C` is the wiki's fire trap is an inference.
- Tempest Shield as a 50 + 7.5 × Attack pool comes from a code comment that cites `GE_TempestShield`. It was not re-read in the dump for this note.
