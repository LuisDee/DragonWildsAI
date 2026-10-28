# Native short local planner evidence, 2026-10-28

The tested deployment remains b29d97b (metadata ab9b90e), DEV ClaudeDev on
client4124, with server7016 and the same Steam/watchdog/navigation helper.
This investigation used zero model calls and did not prove a new autonomous
task. The normal production route guard remained unchanged during these controls.

## Developer control and planner isolation

The reviewed private direct-opt-out control used the existing mover with a
short goal, bounded ownership/deadline/health checks and an independent
cooperative watchdog. It ran for7.078s including observation and cleanup,
recording32samples and only source=memory. A remembered trap exit won route
selection; no typed edge, accepted jump, airborne interval or landing was seen.
It ended inconclusive, with HP100 and actual position approximately
[77.0456,1875.1556,-35.098]. Timer cleanup, raw idle and watchdog termination
were separately verified. This was assisted configuration diagnosis, not a jump
or goal pass. Existing memory was preserved; no route was cleared to force a result.

A separate read-only observer then invoked the actual localplan.lua using the
actual measured/perk envelope and the already selected Player trace profile.
It adapted the mover's unexported trace closure without recalibrating or changing
that profile. It performed no movement, arbiter claim or persistent memory writes.
The first50ms/12-trace diagnostic cadence expired during verification after
732traces/two replans. Its result is unknown, not no-path. The corrected observer
requested the production1ms cadence and actual configured16-trace budget,
retaining the five-second game-clock and independent wall-clock cancellation.

## Actual planner result

The corrected native observation returned a trace-verified candidate with
seven points,741traces,three replans and50expanded nodes. The requested floor
goal was[77.41,1869.65,-32.18]m; the endpoint was approximately
[77,1870,-32.17258]m, about0.539m away horizontally and0.0074m vertically.
The observation itself supplied no arrival tolerance. This endpoint would fit
the existing1.5m default but must be rejected if a subsequent caller asks for0.5m.

| Point | X m | Y m | Floor Z m | Planned action |
|---|---:|---:|---:|---|
| 1 | 77 | 1875 | -35.97796 | walk |
| 2 | 78 | 1874 | -36.00445 | walk |
| 3 | 78 | 1873 | -35.81546 | walk |
| 4 | 77 | 1872 | -34.60636 | walk |
| 5 | 76 | 1872 | -33.74604 | walk |
| 6 | 77 | 1871 | -32.17258 | jump |
| 7 | 77 | 1870 | -32.17258 | walk |

The planned jump rises about157.3cm, below the observed measured164cm single
jump envelope; measured double jump307cm and its perk were also available.
The preceding slope segments fit the planner's existing slope rule. None of
this proves physical traversal or landing: the pawn did not move. HP stayed100,
position was unchanged, timer cleanup acknowledged, raw body idle verified and
the watchdog finished without expiry. The native interval including command,
observation and cleanup was4.344s, not a per-query processor benchmark.

This evidence supports investigating the route guard's early return before
local planning. The candidate implementation must admit only complete routes
to the original short goal, bind their ownership and identity, preserve the
outstanding oracle operation, and observe a real jump landing before advancing
or learning. Long trips retain their oracle requirement. It must not turn this
planner result into a universal collision/safety claim or scripted task solution.

Private evidence: R/logs/recovery/typed_control_af1cef4509.json,
lp_observe_df653c45af.json and lp_observe_4457c972ea.json, where R=C:/gameserver.
Declared nutrition support totals60Bread/83CleanWater for R26. These supplies
and ordinary reflex consumption are assistance, not autonomous survival.

## Search record

Reuse the actual queries and opened primary sources in
docs/design/short-local-route-authority.md and the earlier native navigation
report. [Epic navigation links](https://dev.epicgames.com/documentation/unreal-engine/overview-of-how-to-modify-the-navigation-mesh-in-unreal-engine?lang=en-US),
[automatic links](https://dev.epicgames.com/documentation/unreal-engine/automatic-navigation-link-generation?lang=en-US)
and [Mineflayer pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder)
provide conceptual planning/execution precedent. Reuse the existing local
planner, collision calls, measured envelope and movement ownership; adapt
admission and landing verification after review. Current Lua/native observations
remain the authority for actual units, callback behavior and outcomes.

## Deployed control and inventory observations (2026-10-28 10:30 Berlin)

Source2bff707 passed1197tests/1skip CHECK_ALL: GREEN (485.40s) and was
pushed/deployed with all21 preserved world/statefiles unchanged during the
client-off window. Client7704/ClaudeDev/pawnBP_PlayerCharacter_C_2147473120,
server7016/Steam3284 retained; loopback DEV and forbidden-target guard verified.
The first default-route control refused before starting: native health was1,
hydration0. The developer replenished8Bread/8Water and set health100 through
existing DEV fixtures, explicitly assistance, not autonomous survival. R26
nutrition grant totals are68Bread/91Water. Existing consume path subsequently
confirmed hydration rose49.2->74.1; health remained100.

The corrected private default-mode control omits nav and tolerance overrides.
It started at the original position/goal but made no movement:17move ticks and
272traces, still sampling after approximately13.3game seconds. The10second
control deadline stopped the mover;15second independent watchdog also expired
and acknowledged cancellation. Timer cleanup/rawidle/parentterminal verified.
No jump/air/landing/acquisition or autonomous pass. Raw evidence:
R/logs/recovery/default-route-default_4557708dec.json (refused),
default-route-default_8f91aadfe5.json (sampling-only),
r26-nutrition-restoration-20261028.json and r26-developer-drink-20261028.json.

Read-only FPS settings showed30cap, no foreground-idle limiter. This does not
measure actual frame throughput. Offline instrumentation of actual mover found
51route checks,103uncached world resolutions and52arbiter loads per16trace
callback. The fresh arbiter's housekeeping also lazily loads the entire mover;
its causal live cost remains to be measured before attributing the slowdown.
A narrow existing dependency-injection repair is under review; do not remove
per-trace identity/lease checks to meet a deadline.

Native scalar inventory observations completed without slot-array traversal.
Main8filled/8690items matched all8observed rows; loadout4/268 matched its4rows;
personal0/0. After declared nutrition grants and real consumption, stable
before/after main10rows/8702quantity matched native10filled/8702items/166empty.
AirRune231 and WaterRune560 matched native positive getters; loaded typed
StoneAxe returned0 in all3components. Main/loadout overlap must not be added.
This supports carrying/loadout observations; both hand readers still report
unknown, so a strict no-axe baseline is not yet established. Evidence:
R/logs/recovery/inventory-scalar-native-20261028.json and
inventory-scalar-positive-native-20261028.json. No game-model calls this wave;
UTC spend remains$0.0259/23Haiku calls, zero planner/unpriced calls.

The10:15checkpoint was met;10:30developer validation slipped on real sampling
throughput. Revised Berlin targets:10:45developer validation,11:00Haiku attempt,
11:15chain verdict,12:45repeat/generalisation/M1audit. These are delivery targets,
not guaranteed gameplay success or a waiver of the unchanged goal criteria.
