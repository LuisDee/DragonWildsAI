# Recipe re-measurement and shield control, 2026-10-28

## Tested deployment and information

Source 72a8e37 passed 1198 tests with one skip in 389.34 seconds,
CHECK_ALL: GREEN. All 15 frozen hashes matched; judges were unchanged.
Publication preserved all 21 saved world/client-state files while the client
was off. Server 7016 and Steam 3284 were retained. DEV client: 9820,
ClaudeDev, pawn BP_PlayerCharacter_C_2147473115. Companion hash:
bec14c6d064ec51c; body f0158e63a3dfbeb4; judges b5057d95be92c264.

The actual Controller read path, with the discovered body manifest, receives
all 24 axe candidates for limit 25, including Stone Logging Axe with an
observed unlocked recipe. Native ingredient observations report 17 ash logs
and zero stone, with main-inventory scope and provenance. An earlier developer
projection used a legacy schema lacking these dynamic tools; its diagnostic
is retained. The corrected manifest-backed control passed without API calls.

## Exact-request repeat: new axe still not crafted

The sole request remained: "Can you make yourself a new axe, then cut down a
tree?" Existing equipment and memory were preserved under record_only policy.
Four Haiku controller calls, zero planner calls, 60.86 seconds, cost $0.0049.

It selected the unlocked stone axe and queried craft_plan, then said it already
had an axe and chopped with the old one. There was no build or craft call; axe
count stayed one. The gather reply confirmed five additional logs; independent
inventory rose 17 to 28 and Woodcutting XP 269 to 343 (level 7 to 8). Extra
inventory gain is recorded separately from the gather reply's attribution.
The new-axe objective failed. The visibility fix changed its selection, while
the planner's inventory-target semantics still satisfied the root with owned
stock. Additional production versus inventory targets is a separate reviewed
design; it is not yet deployed. No phrase mapping or forced action is used.

The pilot and parent terminated with successful idle verification and no
watchdog expiry. Raw evidence in runtime logs/recovery:

- postfix-native-controller-20261028.json (legacy-schema diagnostic)
- postfix-native-controller-v2-20261028.json (successful Controller read)
- no-axe-pilot-20261028-105806-bf394f01.json
- haiku-postfix-postfix_4b51c0941f/parent.json
- recipe-publication-65caa55b/publication.json

UTC API spend was $0.0402 over 35 Haiku calls, no planner or unpriced calls.
No tools, crafting materials or stations were granted. R26 support totals are
76 bread and 107 water, plus the earlier single health restoration and declared
test-scene position. This is not autonomous survival or a full milestone pass.

## Developer-selected Tempest Shield

The ordinary cast tool succeeded. Independent native probes showed Air Runes
231 to 216, and newly present Player.Status.TempestShield plus
BP_TempestShieldGameplayEffectInstance_C. Both tag and effect were absent
beforehand. The body reported cooldown started and return to DIM_Gameplay.
Health stayed 100, with no action or waiter remaining. Probe/control interval:
4.907 seconds; body cast timing: 4.01 seconds.

This proves current-code casting with a game-observed effect, not unaided
tactical selection, damage absorption, coverage or a formal milestone. Raw
control: R/logs/recovery/developer-tempest-shield-20261028.json. The existing
data/spell_effects.json proof was read and not changed. No model calls were used.

## Research provenance

No casting implementation was written. The control reused the deployed tool
and unchanged native benchmark probe. Actual candidate/count searches are
recorded in recipe-candidate-visibility.md, recipe-native-item-counts.md and
r26-unaided-tree-chain-20261028.md. Primary precedents include
[pagination](https://google.aip.dev/158),
[query shaping](https://learn.microsoft.com/en-us/azure/search/search-query-create)
and [result sizes](https://learn.microsoft.com/en-us/odata/concepts/queryoptions-overview).
These establish API precedent; live measurements establish runtime behavior.
