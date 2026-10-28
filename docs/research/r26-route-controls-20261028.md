# R26 stationary route controls, 2026-10-28

Sol drove these diagnostics through the existing live queue on deployed source
`83f0ce315a9b44130491da349a6eb1426374d4a4`, before publishing the route-authority
candidate. DEV client 12340, ClaudeDev, pawn
`BP_PlayerCharacter_C_2147473119`, and local server 7016 were retained. There
were no model calls, movement commands, health writes or memory resets.

The starting position was `[63.153,1875.565,-35.446]` metres. A query to the same
XY and 50 metres above returned `no_path`, zero points, and the legacy fields
`partial=false, goal_projected=false` (11 ms reported by the experiment). A
query two metres east at the original Z returned two points, a 2.02 m route,
and `partial=false, goal_projected=true` (2 ms reported). These timings exclude
IPC and are not movement or throughput measurements. The legacy native getter
handling can collapse errors into false; these recorded fields do not establish
that every negative native read succeeded.

The character's before/after position was identical at probe precision, health
was 100, and the terminal client ping had no action or waiters. The queue case
`route_oracle_stationary_baseline_20261028` was observed, not scored as an
autonomous pass. Its active duration was 2.1 seconds. Raw evidence is private at
`R/logs/recovery/route-oracle-baseline-20261028.json` and in the 2026-10-28 live
queue log. Here `R` means `C:/gameserver`.

Before the controls, a separate declared harness setup supplied eight Bread and
eight Clean Water. The existing real-input reflex consumed one Bread and two
Water during its first observation; health subsequently recovered to 100. The
setup took 17.6 seconds and is assistance, not autonomous resource acquisition.
R26 declared nutrition totals are now 40 Bread and 59 Clean Water. Existing
world, death and learned navigation data were preserved.

These controls establish a useful negative/positive contrast for the next
deployment. They do not prove that movement holds during failed planning, that
the new protocol works live, or that the companion can craft an axe or fell a
tree. Repeat the relevant contrast after the candidate is reviewed, gated and
published, then validate actual route admission and a benign nearby arrival.
Further live travel is waiting for those candidate checks, rather than repeating
the failed grave route or already observed easy cases.

## Current-code publication and developer controls

Source `50111a7163e7042b97a1ded800c0e953c19896ef` passed the full gate:
1,192 passed, one skipped, 427.07 seconds, CHECK_ALL: GREEN. Independent review
caught and resolved a producer/consumer UUID-format mismatch and reentrant
arbiter ownership checks. All 14 saved files matched through the gate.

The client and old helper writers were stopped and independently verified
terminal. Server7016 and Steam3284 stayed running. All21 backed-up state files
were unchanged during publication. The separately deployed server experiment
was backed up and received the exact tested bytes; no wholesale mod deployment
or server restart was used. The new helper wrapper3228/worker1980 completed its
same-channel recovery barrier and published a v2 offer. DEV client1416,
ClaudeDev, pawn `BP_PlayerCharacter_C_2147473121`, rejoined127.0.0.1:7777.
The boot itself took37.3s. Watchdog12580 supervises the retained runtime.

The sameXY+50mZ required move returned `verification_failed` with
`route unavailable: no_path` in0.5s. The matched v2 response reported zero
points, partial=false and goal_projected=false. Native position stayed exactly
`[63.153,1875.565,-35.446]` at probe precision, health100 before/after, progress
elapsed0, no stuck events, and the final bridge/arbiter state was idle. This is
no observed displacement; the diagnostic did not instrument native input calls.

For the positive control, the existing `oracle_primary_cm` was temporarily
changed from1000 to100cm so the measured two-metre corridor exercised required
route admission. This is configuration assistance. One matching epoch/nonce
produced a two-point2.02m route; source was `nav`, nav_required=true and the
binding recorded generation2, token3, worlddev. The move arrived in0.849s,
moving1.8m to `[64.953480300842,1875.569511199,-35.25008882518]`.
Fresh arrival checks recorded distance0.269m against0.4m tolerance and vertical
distance0.196m against1.76m tolerance. Health stayed100. Protected cleanup
restored1000cm; a separate final read verified no override, idle bridge/arbiter,
no waiters and an offered helper. Only then was the owned reservation released.

Native-active step time was2.5s for the negative and3.3s plus0.5s cleanup for
the positive. Readiness waits are separate. Both were developer observations,
not scored autonomous or default long-distance passes. Raw source manifests,
memory backup, process identities, request/response files, native observations
and cleanup evidence are private under
`R/logs/recovery/route-authority-publication-a8613c4e/`.

No game-model calls were made: UTC spending remained$0.0125 from11 priced Haiku
calls, zero Sonnet/unpriced calls. The full no-axe task and M1-M6 remain open.
The next task is the capped unaided deployment-model test, with a fresh dev
admission and the existing cooperative cancellation/owned cleanup safeguards.
The helper policy still requires new evidence after a server/bridge restart;
these controls do not establish universal ground support or fall safety.

## Search record

This diagnostic reuses the reviewed route-authority research. Actual queries:
`site:recastnav.com Detour findPath partial result DT_PARTIAL_RESULT path corridor`;
`site:dev.epicgames.com navigation path partial path project point navigation Unreal Engine`;
`site:github.com/recastnavigation/recastnavigation DT_PARTIAL_RESULT findPath last best`.
Opened primary sources include [Detour findPath](https://github.com/recastnavigation/recastnavigation/blob/main/Detour/Source/DetourNavMeshQuery.cpp),
[DetourCrowd](https://github.com/recastnavigation/recastnavigation/blob/main/DetourCrowd/Source/DetourCrowd.cpp),
[Epic partial paths](https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/AI/Navigation/HasPartialPath)
and [Epic projection](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/NavigationSystem/ANavigationData/ProjectPoint?application_version=5.5).
Reuse the existing DEV navigation experiment and queue. The established APIs
explain projection and incomplete paths conceptually; this game's actual
responses above supply the runtime evidence. No new native API was introduced.
