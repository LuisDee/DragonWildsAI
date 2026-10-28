# Clean-water chain and movement cleanup regression, 2026-10-28

## Baseline and assistance

Runtime body remains e9200ff / companion 7f54b5fea959c273; metadata 9345dec.
DEV ClaudeDev only, existing client/server/Steam, no inventory writes or
teleports during these operations. All processing used real campfire UI.

Developer collection fetched six Dirty Water from the pond. The survival
reflex immediately drank one. The first processing command truthfully found
no station within 60 m; a wider read found a campfire 74.73 m away. Developer
navigation into its search radius and normal craft then made one Clean Water:
one Dirty Water and one Ash Log loaded, output collected, Cooking XP 110 to
111 (level 3 to 4), health 100. The reflex drank that output. These are
declared developer controls and setup, not autonomous acquisition.

Raw R/logs/recovery/m1-water-developer-8a6a0feb,
m1-water-processing-developer-468f138b and
m1-water-processing-developer-reach-6d027d72, each evidence.json.

## Pre-fix Haiku chain: gameplay achieved, terminal check failed

Exact request: "Please make yourself some clean drinking water, have a drink,
and keep some for later." No method, recipe, destination or tool sequence was
supplied. Haiku alone made the following choices:

1. Craft two Clean Water at the nearby existing campfire.
2. Try drinking; three attempts reported consumable verification busy while
   the native survival reflex was consuming. Inventory was checked; a later
   consume completed with hydration 34.6 to 59.6.
3. Collect two more Dirty Water from the pond to replenish the reserve.
4. Attempt processing, receive a truthful no-station-in-range failure.
5. Return to the known campfire by its live ID, then craft two more waters.

The model did not ask the operator for a solution, receive another prompt,
use Sonnet, get grants, or get teleported during the episode. It used native
feasibility/context rather than a wiki lookup. The first batch used existing
developer-collected ingredients and a pre-existing campfire; the second batch
used water the model itself collected. No new-station/from-scratch-base claim.

Native independent evidence before operator cleanup: four Clean Water outputs
across the tool trace, final reserve two Clean Water, wood 35 to 33, Cooking
XP 111 to 115, health 100. One drink was model-directed and another consumed
by the native reflex. Eleven Haiku controller calls, no planner, 164.5 seconds,
incremental $0.0068; UTC total $0.0546 / 52 Haiku calls, zero unpriced.

The pilot correctly returned failure because terminal movement was not idle.
The model's gameplay objectives are observed; this is not a clean overall
autonomous test pass or a GOAL milestone. The parent and child terminated
without watchdog expiry. The original failure remains preserved.

Raw R/logs/recovery/no-axe-pilot-20261028-124426-3264e046.json,
haiku-water-water_95f03194d5/parent.json,
haiku-water-native-after-before-cleanup-20261028.json and
logs/brain-live-20261028-134140-12220.jsonl (episode chat-0001-8953).

## Repeated orphan and supported recovery

After developer processing, bridge action/waiters were empty and the arbiter
had no owner or suspended entries, but generation 7 remained go_to with
owner_token absent, owner_implicit=false, 0.4 m tolerance and 1.1905 m target
distance. It incremented ticks while stationary. Goal was near the campfire
interaction/pickup point. A plain stop returned interrupted and did not clear
it. An ordinary new go_to to the freshly observed current position replaced
the known root-owned orphan, acquired legitimate implicit ownership, arrived,
and returned verified idle. No raw Lua-state write or bridge reload was used.

The Haiku processing chain reproduced the ownerless mover (distance 1.09 m)
after the final successful craft. Root first saved native outcome evidence,
then used the same supported replacement and verified idle. This recovery is
operator assistance after the episode, not a silent autonomous pass.

Raw R/logs/recovery/water-craft-orphan-recovery-20261028.json,
water-orphan-supported-replacement-20261028.json and
haiku-water-orphan-recovery-20261028.json. Source diagnosis found processing
pickup omits the parent token, while the shared episode can enter facing and
forget an active child before stopping it; parent finish releases ownership.
Those are confirmed source defects. The precise original gen7 creation path
remains a causal hypothesis, supported by runtime target/token evidence.

## Candidate and next measurement

An isolated W ownership fix is under development and review. It must pass
targeted real-module tests, cold review and full gate before publication,
then developer processing and the unchanged natural request must be repeated
with native output, hydration/reserve and clean terminal checks. Do not
silently weaken idle admission, count a model claim, or overwrite the red run.

Developer berry collection later harvested nine real Redberries plus one seed
to replenish low food while the candidate was developed. No food grant.
Raw R/logs/recovery/m1-food-developer-b02e9da2/evidence.json. All world memory
is preserved. Research and cancellation/reentry precedents are recorded in
docs/design/nested-interaction-move-ownership.md; no new planning policy is
being added to solve this request.
