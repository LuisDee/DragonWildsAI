# Live bug ledger

### Explore claims an exit is visible because `the` matches `gather` (2026-10-29)

MEASURED on complete7ccecf6 trial. Both door/gate/stairs/opening queries returned
already_in_sight Ash Logs. Shared scorer matched arbitrary substrings and admitted
the grammatical token `the` inside verb `gather`. Candidate uses meaningful whole
tokens/identifier boundaries/plurals; exact resolver tiers unchanged. Results
state lexical-candidate scope, not complete geometric understanding. Focused
tests and cold review CLEAR; full gate/live validation pending.

### Required NPC navigation suppresses player-compatible learned routes (2026-10-29)

MEASURED: native partial route went behind ramp and stopped2.9m below its goal;
ordinary movement along the actual human line climbed in3.135s/HP100. Recorded
same-world routes existed but mandatory native routing excluded their initial
selection. Candidate reuses directed observed graph proposals and guarded joins,
including a bounded useful prefix, then replans actual original goal. No temple
coordinates in production. See design/player-route-proposals.md; full gate/live
normal guarded replay pending. Physical operator success is not autonomous proof.

### Interpolated floor probes reject physically walkable flat support (2026-10-29)

REPAIRED/PUBLISHED3ff9496, fullgate1279pass/1skipGREEN. Normal developer movement
passed the rejected segment but was extremely slow and failed a separate
coast_reset_limit; no route acceptance. Exact rejected nav
segment was crossed by production-matched normal input117.82cm/0.7705s, grounded
and HP100. Read-only query replay found five flat-floor hits, then a no-hit when
interpolated target elevation plus probe lift exceeded native FindFloor range.
The old floor_not_walkable reason conflated this no-hit with nonwalkable hits.
Resolved-support candidate fixes query geometry, preserves full sweeps and adds
one bounded lower retry only for known nonblocking misses. It resolves all6raw
support samples in historical replay; no full route or autonomous pass yet.
Evidence: private native-input-ab-a705; design: design/resolved-floor-probes.md.

### Walking scan can expire before it enables input (2026-10-29)

OPEN on3ff9496. Actual nearby walking took68s for~3.6m then coast_reset_limit,
2.32m short/HP100. Cache age starts at scan acquisition instead of completion,
while geometry is collected over several polls; later pre-input clock can reject
a just-completed scan. Lifetime coast resets compound this. This is a controller
timing/retry defect, not proof that terrain is unwalkable. Fresh Astra review and
narrow design: design/walk-scan-timing.md; private rfp-trial-a709 evidence.

### Planning repairs can exhaust hourly allowance before an action (2026-10-29)

PARTIAL REPAIR onb68fc5e: fullgate1279/1skipGREEN and actual complete-agent
remeasurement issued movement at23.38s, with zero observed numeric-argument or
global-trivial advisory repair requests. The trial used an explicit60/hour
allowance and resumed the existing task; this does not prove the default20/hour
policy adequate. Native movement still failed; no gameplay pass. The private
wrapper's24call stop caused artificial planning errors/park, recorded separately.

OPEN, measured complete Sonnet/Haiku trial on a9f5782. Actual Director prompt
omits tool numeric bounds, so two leg_m100 requests needed repair against
maximum80; already-true final-state advisories also revised an explicitly
ordered plan, followed by separate risk preparation and late research refusals.
15Sonnet requests plus5earlier requests exhausted the20/hour Director window.
Task3fccd0b3 waited on budget with both checkpoints pending and no movement.
Source/actual inputs/evidence/searches and bounded next repair are persisted in
docs/research/2026-10-29-planner-input-friction.md. Daily spend/account allowance
were available; do not call this provider exhaustion or clear window history.

### Guard exhausts drift resets on a short native route (2026-10-29)

OPEN, developer diagnostic on fd9fa13. After declared DEV survival setup, a
normal go_to toward a nearby candidate beside the recorded barrier moved2.66m
in26.06s then failed `walking terrain: coast_reset_limit`, with health100,
4.46m horizontal remaining and0.016m height error. Native route was nonpartial;
this execution failure is distinct from missing long-route coverage. Guard
allows2cm pose drift while scanning and four resets over its lifetime; the
counter is not reset by a successful corridor. The causal role of braking,
network correction or the lifetime counter remains unmeasured. Need timestamped
pose/velocity/input/scan observations; do not disable collision or infer an
impassable route. Evidence and actual primary-source search are persisted in
docs/research/2026-10-29-player-grounding-native-controls.md.

### Compound task can finish at an intermediate recurrence of final state (2026-10-29)

OPEN, reproduced by complete Sonnet/Haiku onfd9fa13. Director authored a plan
start-at-lodestone ->210m outbound ->return, with global task_success simply
near(lodestone,4m). After the first real34.23m return to that landmark,
Director `_step_done` observed the global predicate true and `_finish_task`
ended the job while both later steps were pending/zero attempts. Haiku then
reported the whole walk-out-and-back complete. Actual traces reject that claim.
The failed task and history are preserved, not cleared or rewritten.

Do not globally force every pending step for all tasks: state-only goals and
auto-requeued loops can legitimately finish early. Investigate explicit
model-authored ordered completion, durable progress through replan/restart and
truthful completion feedback. No frozen predicate/judge edit is authorized.
Details and primary-source research: docs/research/2026-10-29-compound-completion.md.

### Director loses detailed action failure evidence (2026-10-29)

Candidate fix, live validation pending. `_last_results` previously copied only
tool/ok/reason, dropping detailed route and terrain evidence from Sonnet's
continuation/replan input although Haiku received tool results. New bounded
primitive data retention has provider-request capture regressions, source record
immutability and explicit context-budget truncation. Body additionally captures
local candidate-planner failure geometry and sends it through a generation-bound
result. Full regression gate, developer real controls and complete model trial
remain separate gates. This does not fix the far-route local-window limitation
or prove a new autonomous capability.

Candidate full gate now GREEN1264/1skip508.58s; developer and full-model live
evidence remain pending. Keep the world-routing limitation separate.

### Far-route continuation: local improvement is not global reachability (2026-10-29)

OPEN. Source65af2cb real developer far go_to moved to a partial native endpoint,
then failed268.81m from destination. Reconstructed candidate rays hit actual
vertical faces, not a verified false ramp hit. Readonly9m local window cannot
find its required two-cell improvement after12distinct blocked candidates;
raising the replan allowance alone does not repair it. Necessary detours may
initially increase goal distance; local sampled connectivity and model-visible
geometry/alternatives are insufficient. Do not ignore these wall hits or count
native endpoint arrival as task completion. Research/evidence in the grounding
native controls record; original full-agent temple walks remain unmet.

Separate candidate fix: zero/too-small jump reach cannot propose/consume a
low-obstacle hop or bypass a known wall point. Focused23Lua checks/cold review
pass; full gate pending. This does not repair the above world-routing failure.

The narrow hop fix subsequently passed full gate1258/1skip GREEN512.59s;
world-routing failure remains OPEN and no full-agent route passed.

### Player-grounding: copied Distance and straight endpoint interpolation (2026-10-29)

OPEN in movement integration. Native controls reproduce Distance0 for clear/no-hit
and penetrating cases. Do not use it as an overlap classifier. A full-capsule
one-metre chord hit walkable floor; seven native floor-following short segments
were clear. Raising the endpoint floor query alone did not fix the chord.
Typed floor fields and bounded sampling now have diagnostic controls; they are
not yet connected to route selection. Preserve the separate unsafe-memory-entry
and native-coverage bugs. Details: docs/research/2026-10-29-player-grounding-native-controls.md.

Candidate walking integration now passed the fresh1258/1skip full gate and
Astra review. Shared memory-entry/recovery checks, bounded local prefixes,
held-planning deadline and input-bypass regressions are covered offline. Keep
this issue OPEN until native adapter and actual temple traversal pass; no
autonomous route has been newly accepted.

### DEV: disconnected native route and unsafe remembered floor connector (2026-10-29)

OPEN; no autonomous traversal pass. The exact friend-route endpoint was reproduced
by a stationary DEV native query without the mover: nil and explicit Default end
at `[71.68,1862.08,-35.2]`; Gigantic is also partial. Manually walkable ramp
endpoints fail tight projection on Default. This is not evidence for an axis
swap or a simple alternate-mesh fix. Independent current short-move failure
selected trap t7's lower-floor exit while on the upper floor, triggered step-off
recovery and failed landing. Preserve the memory; validate connectors/floors.

Astra also proved an unrelated generic waypoint-skipping counterexample and
broken native index-progress accounting. A bounded reviewed patch is in progress,
not yet deployed; it cannot alone fix the reproduced native partial path.
Evidence and proposed negative controls: docs/research/2026-10-29-astra-navigation-review.md
and docs/design/waypoint-and-route-progress.md. Sol found identity/coverage/read
completeness risks for nearby containers; these are static findings pending live
discrimination, not all confirmed causes of the reported chest failures.

### Friend trial: walkable ramp missed; route context remains unresolved (2026-10-28)

OPEN. Developer real inputs climbed a loaded rubble approach to the upper stone
floor with health 100; Luis visually confirmed the top, then doorway obstruction.
The same trial contains partial native paths and steering toward a waypoint
almost vertically below the character. This is sufficient to investigate a
generic route/layer/steering defect, not to identify a ramp-specific root cause.
The local planner already supports two floor layers and slope verification.
See `docs/design/pathing-ramp-investigation.md` for the discriminating DEV test.
No movement-policy change has been implemented or validated from this trial.

Additional observed gaps are parked separately: body death memory exposed old
DEV deaths to the fresh friend character; remembered death coordinates were
about 46 m below the live registry's safely placed gravestone; `explore("rat")`
matched visible raw meat; and the model lacked the fatal cause available in the
raw log. Do not clear memory or hide those failures. Native KillZ death and a
later dehydration death are distinct events. Some operator diagnostics also
stalled the client and required a disclosed client-only restart.

### Navigation failure feedback implemented; deployment proof pending

2026-10-28: candidate retains validated route endpoint/partial/projection facts
even when movement policy rejects that route, and reports measured horizontal
and signed/absolute height error without rewriting the requested goal. Exact
query-goal identity is metadata-only; no routing/retry/arrival changes. Stale,
malformed, foreign or resumed-generation evidence is omitted. Cold review caught
an unsafe diagnostic read before pawn/controller validity; guarded before and
after native reads, with zero-read invalid-identity regressions. Full gate1249/
1knownskip GREEN. This does not yet establish better unaided navigation.

The nearby construction failure has a positive control: on unchanged deployed
53fd3f7, moving21m to a different site then building/using a new Lodestone worked.
The model's earlier false missing-materials claim and original300m chain remain
open; do not introduce a forced plan or infer every failed placement's cause.

### Lodestone task chain now blocked by navigation/placement and model choices

OPEN (2026-10-28). On53fd3f7 the full developer approach/use/arrival/UI-cleanup
passes, and one unaided Haiku teleport129m passes under declared fixed-zero
headless menu presentation. The original300m/build/return remains FAILED.

Recorded server bridge pairs establish: first300m goal has goal_projected=false,
no_path after corridor loading; alternate goal has goal_projected=true and
partial=true, ending[67.2,1857.6,-35.5], not at[120,1800,-35]. Do not infer an
engine crash, particular terrain cause or repair from these flags. Existing
explore searches entity text: 'open flat ground' matched a chest's Open prompt;
it does not measure terrain flatness.

Local chain's buildables card said can_build_now=true, but Haiku chose only
teleport and claimed missing32Stone/20Essence/1Core, all carried. No code
overrode the raw provider choices. Separate construction-only request did
produce build; real preview rejected near-base spots. Its repositioning guessed
Z=-22 (no projection/path) then Z=-33: native full projected path ended at
[180,1797,-28.38], while pawn reached[180,1797,-27.59]; go_to still failed
no_route. Exact-Z semantics/ground projection feedback need a bounded design;
do not silently substitute a projected floor or loosen arrival criteria.

### Mining level-up: failed action feedback and bounded continuation (2026-10-28)

OPEN. In mining_level_83115a601a Haiku initially selected an observed depleted
boulder for attack/interact; the subsequent gather independently approached a
living boulder and returned inputs_not_reaching_game (0hits/6swings), while
native Mining XP rose35 -> 42 across the episode. Do not infer attribution or
root cause from that discrepancy. It then selected pickup mode (honest
expected_training=none), handled hydration and exhausted the allowed continuation
slice with the original request retained. Level2 did not advance. Eleven calls
and130s were below the private pilot's20-call/300s limits.

One developer repeat on unchanged5d2f662 verified a different living boulder
75HP -> 0, six reported hits/seven swings,10Stone,+13MiningXP and28durability
spent. Thus a universal broken mining input path is not established. Preserve
both traces; next diagnosis must discriminate the failing target/observation
and control conditions before changing policy, caps or hit accounting.

### New-axe intent failure no longer reproduces in one carried-stock trial

Unchanged exactrequest completed: afterinitialcraft no-station failure Haiku
builtCraftingTable, craftedadditionalaxe andfelledanother tree. Stock/different
worldhistory confoundhistoricalcomparison; thisisonepostfixsuccess, notproof
feedbackrepairalonefixedmodelintent. Newaxeinstanceusageunknown(equipalready).
Keep originalfailures/fromscratchresourceobjective open untilmatchedrepeats.

### Continuation feedback repair verified in actual Haiku input (2026-10-28)

5d2f662 is pushed/deployed. All3actioncontinuations of7callwater/build/process
trial carried the newboundedcurrentobservation, including changedposition,
hydration and newstationID/distance. Originalrequest andper-callresults stayed
inactualproviderinput. Nativeoutcomesandstrictcleanup passed. This verifies
feedbackdelivery; N=1 anddifferenthistoricalbodydo notestablish causalrate
gain orfullperceptioncoverage. Freshinventorysummarycanstillclip low-priority
items behindlarge rune stacks; honestomission/readconfidence remainsvisible.
Initialsummary/perk/UIcoverageandlegacyPlanner pathsremainfollowups.

### Fresh continuation state omitted from provider input: repair gated (2026-10-28)

Controller.next_turn now appends bounded supplied-current observation after
all call-ID results and before continuation instructions. Captured-provider
regressions cover changed position/vitals/inventory/station distance, failures,
unavailable reads and deferred resume without action replay/extra calls.
Sol approved, full gate1245/1skip GREEN410.69s. Native/model repetition still
required before claiming improved gameplay decisions. No broker history is
substituted for an unavailable current read. Initial-summary clipping and
broader lifecycle/perk/UI coverage remain separate known limitations.

### Nested movement lifetime and headless Lodestone UI lifecycle (2026-10-28)

Source-confirmed: crafting collection omitted parent move token; episode near
transition could abandon a running child; terminal parent release did not
ensure child cleanup. Candidate propagates token, binds exact child generation
and drains only that child. Sol review/targeted tests passed; full/native
revalidation pending. Bridge timeout still drops its action without confirming
cancel cleanup; do not claim universal cleanup guarantee.

Lodestone old map close treated an empty closed-list table as success and
trusted MapUIAPI false while Map13/TopBar29 still blocked gameplay. Candidate
reads actual screens, exact active local menu ownership and later closure.
A repeated normal0.4 interaction produced a new API parent but stale active
root-stack widget. No teleport was sent. Fresh zero-duration control completed
one real teleport and UI cleanup; repeated fixed-zero control next. NullRHI
Slate transition hypothesis remains unproved, temporary presentation guard is
not a final fix. Keep native/Haiku chain status unpassed. See r29 research.

### Published model arguments disappear before dispatch (2026-10-28, verified)

Controller live dispatch repaired in 9516fc3, full gate GREEN and native
inventory raw-mode before/after control passed. GameInterface was a second
lossy normalization boundary; both now use the manifest. Keep this issue
open for legacy Planner/learned-skill schema drift and native option controls;
do not claim complete full-stack schema authority yet.

Capabilities.validate accepts the native manifest, then legacy Pydantic
models silently discard craft station/recipe/fuel, attack weapon/style/force,
gather stumps/style and inventory raw. Recipe-only craft can be rejected by
the older required item field. Actual water log response line150 selected
a station, dispatch line170 omitted it. Manifest must be authoritative,
with explicit validation failures and declared defaults; no hidden rewrite.
See research/2026-10-28-sol-adversarial-architecture-audit.md.

### Continuation inference lacks refreshed surroundings (2026-10-28, verified)

Agent refreshes state, but Controller.next_turn appends only tool results
and generic instructions to the prior messages; the fresh state feeds reads
and collection, not the next provider observation. Long actions therefore
leave original location/vitals/station context in history. A current bounded
observation with freshness/uncertainty and unchanged root intent is needed.
Do not replace this with task-specific instructions or blame every failure
on Haiku. Fix and compare captured provider inputs before live measurement.

### Successful processing leaves an ownerless approach mover (2026-10-28, reproduced)

Developer Clean Water and the natural Haiku water chain both completed
processing but failed clean terminal admission: bridge/action/waiters empty,
arbiter no owner/stack, move mode go_to spinning stationary. Gen7 capture:
owner_token absent, owner_implicit=false, target distance1.1905m, tolerance0.4m.
Ordinary stop returned interrupted and failed to clear it. A guarded normal
go_to to current position recovered idle without raw-state writes/reload.

Source defects: processing-output pickup omits job.token; shared interaction
episode may switch to facing without draining its child; crafting finish
releases parent. Exact original generation attribution remains a hypothesis.
Fix design nested-interaction-move-ownership.md requires ownership admission
before mutation and generation-bound teardown with reentry/suspension tests.
See r28-clean-water-chain-20261028.md. Do not convert the red pilot to a pass.

### Phase Dash diagnostics lack the base Air Dash prerequisite (2026-10-28)

Four-pump directional native controls retained 1.2173 m before a fresh cast
and 1.0414 m after; no dash benefit established. Read-only native active_perks
contains DoubleJump/Hopper but no Air Dash; Agility is 22 while the wiki
describes Air Dash at 32. Artificial utility-spell unlock does not establish
the base movement perk. Treat this as a likely prerequisite/setup gap, not a
verified production failure or reason to patch movement. No leveling/reset
fixture was used. Full evidence in r27-m1-controls-and-mobility-20261028.md.

### Passive native control observations collide with food/drink ownership (2026-10-28)

The new diagnostic runner correctly refuses unknown/busy effect dispatch,
but it also demands idle for every read-only final probe and passive wait.
Food/drink reflexes therefore interrupt otherwise completed native controls;
root preserved these blocked runs and retried only after actual idle. Positive
and claims-only controls completed; do-nothing full-window remains unrun.
Before implementing an observation-only admission path, research/review it;
retain strict dispatch/identity/foreign-owner protections and record ambient
behavior rather than disabling survival reflexes.

### Native controls and build provenance missing from formal evidence (2026-10-28)

The frozen goal checker requires native DEV positive/negative controls, while
the existing controls command only performs mock lint. No DEV validity writer
or scripted combat oracle exists. Catalog/game_build is 26161880, whereas the
running client reports 26162923. New non-judge control diagnostics preserve
both builds and do not publish official validity; review actual correspondence
before claiming current-build certification. Full-manifest preflight was
actually checked: 202 trials x six Haiku calls ceiling $4.27 plus spend fits
the $10 cap; --max-runs still preflights all trials, and final scoreboard only
appears after the full manifest. Do not count partial --only runs.

### Old air-dash probe does not establish directional evade (2026-10-28)

Developer comparison on e9200ff: both before and after a successful Phase Dash
cast, the probe saw a 1.8 m jump, falling=true and injected=true but horizontal
motion zero. It injects EvadeAction for one frame with no MovementAction;
production combat supplies direction plus a four-frame tap. This is not proof
that production dodge or the spell is broken. A reviewed private directional
control must isolate this difference and measure native retained movement.

### Production request dropped despite corrected planning contract (2026-10-28)

On deployed e9200ff, native Controller validation proves additional_output
plans one new axe despite holding one; inventory_target reports stock satisfied.
The natural request repeat never invoked craft_plan: after recipes/stations,
Haiku attacked an unknown tree target, then chopped with its old axe and ended.
No new axe/table; Artisan and Construction XP unchanged. Remaining failure is
not evidence that the corrected planner returned owned stock as new output.
Inspect supplied intent/continuation context before another implementation;
do not force tools or delete equipment to conceal the failure. Trace:
R/logs/brain-live-20261028-123103-7084.jsonl, episode chat-0001-0b2c.
Cold review confirms the full request reached the model and accumulated
messages remain in subsequent calls; no conversation-loss defect established.
The model also treated unknown recipe unlocks as if excluded. Replay captured
context offline to assess repeatability before changing implementation.

### Craft planning confuses owned stock with additional production (2026-10-28)

After candidate visibility was fixed, the same new-axe request selected the
unlocked stone axe, but craft_plan count 1 returned an already-owned result.
Haiku used the old axe. A new axe/station was not created. The generic quantity
mode design separates additional output from reaching an inventory target;
it must preserve real observations, ingredient stock and model choice. No
phrase mapping or equipment deletion is a solution. The W candidate is under
review/testing; deployed R remains tested 72a8e37 until publication.

### Recipe candidate truncation hid a viable basic tool (2026-10-28)

A request to make a new axe and cut a tree matched 24 recipe outputs, but the
ambiguity response returned only 15 despite a requested limit of 25. The basic
stone axe was outside that slice. Haiku chose locked bronze, abandoned crafting
and chopped with its old axe. The compound request failed; neither a new axe
nor a station was created. The reviewed generic visibility fix honors limits
and exposes observed unlock information without choosing a recipe.

The new metadata treats omitted unlock entries as unknown. Older assessment
and plan-tree paths still treat absence from a partially readable unlock set
as locked; that remains a separate truthfulness limitation. Processing still
uses existing inventory traversal to locate transfer slots; this wave does
not certify all slot reads or atomic inventory snapshots.

The first successful tree pilot also reported an idle-schema mismatch because
Lua omits a nil arbiter owner. Root independently verified terminal process and
raw idle state, retaining the original report. The private generic pilot now
checks a complete idle schema both at admission and cleanup; 37 tests passed.

### Active: local-route sampling exceeds real control window (2026-10-28)

On deployed2bff707, default local observation reached only272traces/17ticks
in13.3game seconds, no physical movement. Independent watchdog and cleanup
completed; no goal pass. A fresh arbiter recursively compiling move.lua on
each ownership check is a measured repeated-work source; narrow existing
set_move(actualM) injection is under regression/review. Preserve all existing
world/pawn/life/target/capsule/owner checks and owns_move lease housekeeping.
The separate health1/hydration0 preflight refusal was accurately blocked;
developer nutrition/health fixtures are declared assistance, not survivalproof.

### Required route hold excludes a candidate short local climb (2026-10-28)

The actual local planner found a7point upper-level candidate with a157cm jump,
while the default required-route flow stops before local planning on this class
of upward goal. This is evidence for a missing admission path, not proof of a
safe climb. Existing ordinary jump/djump waypoint advancement can also occur
before verified landing and trigger premature success learning. The isolated
fix couples complete original-goal local admission with an owned landing
transaction; it is not deployed yet. Preserve long/partial oracle behavior and
strict requested tolerances; do not clear memory to force a developer result.

### Craft-plan alternatives fixed; physical acquisition still blocked (2026-10-28)

b29d97b's native response exposes the ingredient alternatives and retains count
uncertainty. Legacy recipes/craftable remains a separate information gap.
Pickup/path failure persists. A current paired context experiment found the
same partial path for nil/Default; Gigantic completes only after displacing its
start projection several metres. Do not switch mesh or mistake this for a route
from the actual pawn. Existing short typed traversal is the next controlled
capability boundary; keep the failed cases and original goal criteria intact.

### Acquisition options flattened; nearby loose pickup unreachable (2026-10-28)

On9cacd96 the model called craft_plan, whose flattened steps/missing made one
catalog recipe branch look mandatory:42currency for basic materials, despite
nested gather hints. The station kind and recipe name do not prove vendor or
native craft capability. Planning also drops inventory completeness and assumes
absent keys mean exact0. Reviewed generic OR-options/AND-inputs and snapshot
uncertainty work is isolated; actual craft execution gates must be preserved.

A separate developer loose_stones/count1/pickup/radius15 control failed
path_blocked after3unreachable attempts, gathered0. Position moved~5.2m,HP100,
observed inventory unchanged. Fresh loose resources were visible~3m above the
starting character Z. Investigate actual approach/nav evidence; do not relax
safety, claim pickup or infer why from geometry alone. Raw run20261028-075354;
report docs/research/r26-model-gap-native-retry-20261028.md. No retry loop.

Trace audit found partial paths, not helper failure/no_path. A matched-v2
stationary comparison returned the same partial endpoint for resource XY at
both heights. Destination-height adjustment alone is unsupported. A nearby
partial=false path projected~1.28m away from the original requested goal;
partial=false/projection success must not be counted as original-goal arrival.

### Natural task stops before prerequisite discovery (2026-10-28)

After route admission, the bounded natural tree retry survived but did not craft
an axe or fell a tree. Craft/recipe/station/lookup schemas were available; the
model never invoked them or a planner, so no missing-tool or planner-failure
claim is justified. It gathered unsuccessfully, tried a remembered grave, saw
no_path, then asked for a spare. Woodcutting219->219 and inventory unchanged.

The inventory read returned166/8/20 repetitive carried/loadout/personal gap
entries and13,068UTF8bytes. The next prompt grew18,956->25,988tokens, but this
does not establish decision causality. The reviewed candidate preserves all raw
evidence/positive fields/uncertainty while sending a1,929byte model view for that
recorded result. Native ABI/empty-slot proof remains separate and blocked on
current reflected layout plus independent memory access; fresh VM_READ denied.

The private pilot's terminal check falsely rejected omission of an empty arbiter
owner field. Its original exit1/unknown cleanup result was not overwritten;
parent verified raw owner/stack idle, correct living avatar and driver processes
terminal before release. The final speech appeared once; the extra model reply
was talk-only verification, not duplicate spoken chat. No automatic retry loop.

### Required-route fallback replaced; broader safety remains open (2026-10-28)

Deployed50111a7 now rejects a native no_path required move with no observed
displacement, and a configuration-assisted nearby required route completes
through v2 identity binding. The original grave path was not repeated. The
full gate and independent review cover pending/failed/partial routes, ownership
reentry and traversal boundaries; this does not prove universal terrain support.
An unaided tree/crafting retry is still required. The helper's server-restart
bootstrap and native empty-inventory semantics remain open. Keep the raw failed
pilot, death and per-world learning; no memory reset or weakened judge.

### Route authority candidate: live failure remains open (2026-10-28)

The failed tree pilot's no-path-to-straight fallback remains the deployed
behavior until the isolated replacement passes review, offline gates and benign
live negative/positive controls. A stationary +50mZ query now supplies a native
no_path contrast; a nearby2m query supplies a positive route. Neither moved the
character or validates the candidate. The helper's reviewed v2 recovery policy
is pinned to one independently verified server/bridge lifetime; unattended
bootstrap after a server restart remains unsupported and must fail unavailable.
Do not repeat the grave trip, hide learned/death memory, or count a paused
planner as a completed task. Native empty-inventory semantics and broader
continuous support remain separate open issues.

### Native food-reflex compatibility after publication (2026-10-28)

A reserved check supplied two Bread and two Clean Water. The existing client
reflex consumed them through real inputs: food0->59.31, water0->49.08 and
HP0.5->51.5 after15 seconds, thenHP100 on the next read. Read status remained
partial with verified page mapping; this confirms the perception change did
not break this positive use path. No model calls, health writes or autonomous
resource-acquisition claim. The queue and owned cleanup are terminal, and the
actual runtime reservation is free. R26 supplied nutrition totals32Bread/51Water.
Raw evidence: inventory-read-publication-47d69c3a/native-reflex-compatibility-result.json.


### Inventory checkpoint published and checked natively (2026-10-28)

Source `83f0ce3` is deployed: companion `0a0581215e563a39`, body
`de557a16bbfb20c8`. The client-only integration took 50.4 seconds; new DEV
client12340/ClaudeDev, server and Steam retained, all21 preserved files
unchanged. Native inventory/get_state preserved all eight known carried counts
and exposed partial/unknown reads. The model digest shows lower bounds rather
than false emptiness. Full gate: **1,168 passed, 1 skipped, GREEN**, 364.52s.

Native empty-slot semantics and count-sensitive verification remain open.
Health was0.5 from diagnostic idle starvation; this read-only check is not
a survival pass. The slot is free and no API brain remains. Next is generic
no-path/partial-route handling. The failed tree pilot, death and memory remain
preserved; total daily API spend is **$0.0125**.


### Inventory perception checkpoint GREEN (2026-10-28)

Full gate1168 passed/1 skipped364.52s, CHECK_ALL: GREEN; source hashes unchanged
(`logs/recovery/cf-394651d8/check-all.log`). Positive observations, per-scope
read uncertainty and lower-bound counts now reach the model without a false
empty claim or guessed item slot. Count-sensitive verification/nativeemptyABI
remain separate. Runtime publication/native read confirmation pending. Natural
tree pilot failedKillZ; route-authority behavior is the next fix, not a success
claim or another known-dangerous travel attempt. UTC spend$0.0125/11Haiku.


### R26 repeated with generic no-path fallback evidence (2026-10-28, OPEN)

Natural tree request selected an old axe grave and died inKillZ04:31:52. Four
structured no_path/zero-point replies did not stop raw-goal straight steering
after local segments. Sourcepath drops failed results and defaults aim togoal
while pending/exhausted. Rootmanualmonitor was too slow; no safety interception
claimed. Plan: existing oracle-required long-trips must hold until owned route
evidence, handle failure/partialend truthfully and retain unresolvedsingleflight
through timeout, without special entity/goal rules. Design approved for bounded
implementation/tests only; no prevention fix yet. Fullfailedtrace/memory kept.


### R26 contrasting typed controls (2026-10-28)

Native -100cm query: floor-block=false but hit-block=true/penetrating=true;
-20cm: walkable=true, FloorDist=-17.84766, penetration=false. HitDistance0
also occurs on the +100cm no-hit control. Treat fields independently; none
alone proves full capsule clearance. Eight new stationary native queries
completed with unchanged physical state and memory, owned cleanup confirmed.
Continuous support behavior remains unimplemented; do not claim prevention.


### Floor-reader logical cleanup was terminal (2026-10-28)

Original standalone reader's closed marker prevented same-process reacquisition. Reviewed isolated fix separates exact logical leases from a versioned native registration ledger, permits the same factory on the same healthy record, and refuses legacy/foreign/ambiguous state.56 actual-hub checks and full gate1158/1 skipped GREEN; runtime enable/rejoin invalidation remain unverified and unpublished. No native hook unregister or forced marker clearing.


### Jump ownership: live flat-path confirmation (2026-10-28)

Sourcec145862 passed developer native movement/owned stop and ONE actual Jump/air/landing/settled check on DEV10824, HP100 and nav SHA unchanged. Exact cleanup acknowledged, final arbiter/body idle and slotfree. Supersession/error branches remain offline regressions; neither ledge prevention nor autonomous route selection is proven. Private runner corrections passed actual queue/two-take and cold rereview before live use.


### Private runner defects caught before native input (2026-10-28)

Queue renews its own slot after acquisition; a free-only wrapper rejected that renewal. Its bridge-start delegate would restart an already healthy bridge. Independent review caught both before helper input. Private corrections now test the actual Runner/two-take flow and skip bridge restart after verified readiness; rereview pending. Sourcec145862 jump binding is published, native confirmation pending.


## Jump cleanup could affect a successor movement (2026-10-28)

Old jump calls could advance one-shot progress after a failed or superseded native call; second jumps lacked a verified airborne binding. Stop cleanup could run after callbacks transferred ownership, and a reentrant route-memory flush could clear a successor trip. Frozen fix captures and revalidates the old movement binding, introduces an exact scoped arbiter stop context, and performs owned native cleanup before completion callbacks. Actual-module regressions include failed calls, pause, transition/reentry, successor preservation and persisted successful arrival. Full gate1158/1 skipped GREEN; live verification and publication pending. No floor-support prevention claim.


One row per bug seen live. Every fix lands with a regression test (PRINCIPLES #10). Status: open → assigned → fixed (test name) → verified live.
Evidence: `client_io/events/chat.jsonl`, `logs/brain-live-*.jsonl`, `logs/client/client.log` (UTC times).

## 2026-10-26 — Recovery wave

### 2026-10-27 follow-up: mixed work/help decision (R22, open)

On deployed cde20004, Director proposed work steps including opening the newly built Crafting Table and also supplied conditional `ask_help`. `_apply` immediately parked task552d7ceb as waiting_help before the plan ran, then selected an older self-care task. Evidence: brain-live-20261027-225655-8912.jsonl and private tree-cde-ordinary-handoff.txt. This does not prove bench interaction fails or that Luis must grant an axe. Inspect and repair the generic decision contract with explicit validation feedback; no phrase matching, silent choice rewriting or benchmark-specific fallback. No fix or regression implemented yet.

Update23:24: reviewed candidate now rejects structurally conflicting decisions through the existing bounded model-repair loop; no prose parsing or choice rewriting. Focused Director/design checks71 passed; integrated Director/knowledge/all client Lua/design118 passed. Full gate62459 currently running against frozen candidate; not yet published or proven live.

### R23 — Interaction screen falsely reported as unchanged (2026-10-27, open)

Developer-driven cde table use approached and opened CraftingMenu; orphan cleanup closed it twice while generic interaction verification ran, then interact returned verification_failed. Native recipe false->true and actor-interaction set5->6, followed by a real successful craft, contradict the claim that nothing changed. Source logs22:15:21–22:15:29, private dev-drive-session-20261027.json. Input ownership and target-linked new-screen verification design independently approved with lifecycle cautions in docs/design/interaction-screen-verification.md; no implementation yet. Preserve existing pickup, grave, bed, talk and container verification, pause safety and orphan recovery; never treat any open UI as success.

Update: R23 candidate implemented/reviewed in isolated UI tree, then integrated. Strict Boolean reads, selected-target station ownership, scoped claims and cleanup are covered by focused Lua tests, including a native-like fake-engine DIM_Resting exit. Sixteen native getter types verified readable on cde, not a candidate-live pass. R16 wording correction and knowledge clipping correction also reviewed/integrated.139 focused tests passed; gate62885 finished GREEN1126 passed/1 skipped. Earlier gate62459 RED was the recipe-card regression, now corrected without weakening its test. Candidate deployment and native remeasurement remain pending.

### R24 — Reports path blocked while the requested shelter is already being used (2026-10-27, open)

Latest R23 status: release528ae99 deployed byte-verified and passed developer-live Crafting Table and Campfire/Processing cases with correct owner,1 press, screen_opened, Gameplay cleanup and no leaked claims. R23 is verified live under developer control; other families/autonomous stress remain. R22 is regression/gate verified, not exercised by the Controller-only pilot.

Controlled developer case234836 on cde: one IA_Interact at22:48:53, movement retries, path_blocked at22:49:26. Subsequent probes independently showed the requested resting-area actor, restingtrue/sleepingfalse/timeframefalse, endurance33->54 over20s. Same-bed exit235156 returned got_up with native restingfalse/Gameplay. This proves daytime rest under the declared test conditions, not the cause/timing of entry or autonomous composition. Source W.press_signals drops resting_in and tests only IsSleeping; its retry can then reapproach while resting. Private audit `logs/recovery/r24-rest-postmortem-20261027.md` records evidence and uncertainty. No repair included in the current candidate; distinguish resting from nighttime sleep and use actual target-linked state, not a bed-name rule or failure suppression.

R24 design independently approved with an explicit prerequisite to establish the getter's actual ABI/read-only contract before production use. The design's known-nonresting baseline is narrower than the older audit's different/empty wording and is authoritative. No implementation yet.

### Diagnostic harness: queued work never executed (2026-10-28, corrected privately)

Original survival_diagnostic.py exited after handle_event while run_skill was queued; first528 pilot2 Haiku calls ran no skill. Reviewed private pumped copy uses actual Agent.step only for pending work, with native evidence/bounds/operator stop;5 real-Rig/fake-model tests passed. Corrected pilot executed its selected skill and collected3 berries, but water failed too_far65.4m and its cap0 planner could not repair. Returned stuck; do not call it complete survival or infer production cannot replan. Trace and learned memory retained. Production/judges unchanged.

| ID | Symptom | Cause | Fix / evidence | Status |
|---|---|---|---|---|
| R1 | Strict provider rejects a speech-only follow-up | Pending say tool_use lacked matching tool_result before the next request | Controller answers say calls before the talk-only check; strict-provider tests in test_speech_channel.py | fixed offline; live confirmation pending |
| R2 | FX checks report failure despite wrapped probe output | Paths omitted result wrapper; counter comparisons lacked process continuity | Wrapped paths, fail-closed expected references, nonempty stable token; test_fx_live_checks.py | fixed offline; fresh live checks pending |
| R3 | Full suite depends on host debugger installation / synthetic judge approval | Dry-run fixture searched installed cdb; synthetic target inherited real judge tag | Explicit test debugger path and missing-debugger coverage; isolated fixture sets judge_tag=None | fixed; full gate GREEN, 1057 passed / 1 skipped |
| R4 | Recovery survival diagnostic did nothing | CommandReceived was injected without an addressed-chat prefix and routed to ignore | Zero controller/planner calls in diagnostic log; local diagnostic now uses normal !c prefix | diagnostic corrected; rerun pending; no gameplay result |
| R5 | Intermittent WinError 5 replacing task_tree.json in two full-suite tests | Duplicate task-state writer lacks the bounded Windows-lock retry used by other memory stores; ACL grants Full to the owner, exact lock holder unknown | Reuse brain.fileio.atomic_write; transient and persistent denial regressions in test_fileio.py; 43 focused tests pass, Terra cold review clear | fixed offline; full gate GREEN, 1057 passed / 1 skipped |
| R6 | Silent successful add_task can produce misunderstanding fallback instead of a model reply | Non-body tool results neither count as activity nor trigger continuation; body ran list intentionally excludes board tools | Successful non-body results count as activity and return to model for an unspoken user command; preserve body-only preemption. Text/say success/failure regressions with pending worker; 158 focused integration tests pass, Terra review clear | fixed offline; full gate GREEN 1061 passed / 1 skipped; live measurement pending |
| R7 | Typed local-plan superjump edges had no executor | Interrupted traversal wave generated edges but only executed jump/djump | Borrowed Windstep cast, fresh gates, owner checks, cancellation-before-handover and grounded endpoint proof; regression covers path invalidation during flight and unchanged memory routes | fixed offline; full gate GREEN 1061 passed / 1 skipped; calibration/live traversal pending |
| R8 | collect_water reported Goblin Pack x2 as water | Shared episode chose largest inventory delta from before approach, without expected source identity | Native WaterItemData reflection; accepted-source identity, pre-press baseline, matching gains and actual-source aggregate/partial records; 60/60 skills tests pass; cold review clear | fixed offline; full gate GREEN 1067/1 skipped; live pending |
| R9 | Flee reached destination, stopped moving, died six seconds later in live self-care diagnostic | step_flee never renewed completed movement while observed threats remained; old unsafe activity could misleadingly say fled | Bounded observed escape continuation, ownership, persistent movement errors, unknown-state handling and true failure activity; 396 targeted combat/arbiter tests, final cold review clear | fixed offline; full gate GREEN 1067/1 skipped; no live improvement claimed |
| R10 | Calibration could bless ordinary jumps or overwrite unrelated envelope data | No confirmed second-jump evidence, partial samples, truncating writes and numeric-only reader trust | Complete observed samples, per-field provenance, data preservation/retained backup, bounded waits and cleanup; targeted suites/cold review pass | positive native calibration/reader verified on528ae99,9 grounded trials; traversal/Windstep still pending |
| R11 | Live queue skipped a healthy-looking client between watchdog probes | Watchdog publishes ok_unprobed between in_world samples; queue requires in_world | Fresh-sample wait used for measurement; guards unchanged | open ops readiness issue |
| R12 | Later full suite failed replacing scenario target lease | Scenario lease and two ops state writers duplicated bare Windows replacement instead of shared bounded-retry helper | scenario_run, client_slot, live_queue reuse brain.fileio.atomic_write; six injected transient/permanent-denial tests; 38 focused ops tests and cold review clear | full gate GREEN 1067/1 skipped |
| R13 | New bridge kept an obsolete stay-fed crash restriction despite empty current risk data | Supervisor adopted globally healthy loops without invoking the new module's idempotent start; callbacks could retain older module-local risk cache | First adoption rebinds once; false/failed/unhealthy adoption remains pending with backoff; 11 bridge tests, final full gate GREEN 1067/1 skipped. Native deployment 15:59 Berlin adopted all six services, each starts=1/pending=false; fed and guard loop IDs unchanged, policy/orders preserved | verified live; 7c6a2e2 |
| R14 | Commanded drinking and automatic survival drinking overlap during the short M1 pilot | Command consume pressed before pawn ownership; fed reflex and combat uses had independent pending verification. Overlap observed; game cooldown causality unproven | Shared owner/item transaction, one input and interrupted lifecycle cleanup; review approved, 400 combat checks, full gate 1067/1 skipped. Native 20261027-201444: first food request truthfully deferred busy/pending verification, retry consumed Bread with observed count/stat change; gate idle afterward | directed native verification passed; autonomous stress pending |
| R15 | Board marked cut down a tree done after picking one stick | Gather can substitute equivalent material from a tool-free profile; model selected inventory gain as proof of requested work | Task87658e1c, brain-live-20261027-203109-8512.jsonl: zero swings/hits/breaks, unchanged WCXP206, no axe/bench/craft. New profile-mode contract and generic planning guidance under reviewed design; retain useful material fallback, no judge edits | PhaseA reviewed and full gate GREEN1069/1 skipped; live remeasurement pending; no-axe proof FAILED |
| R16 | Self-care model deferred resting to night with endurance0 | Context says restored by sleep and too early to sleep, omitting observed UI distinction between daytime nap/rest and night skip; sole causality unproven | Native UI text/prompts in DISCOVERIES; read-only research locates situation.py and sense sleep-window data. Actual daytime recovery still needs measurement | open perception/knowledge gap; parked behind R15 |
| R17 | Some repeated consumable uses still fail verification after serialization | Game refusal/cooldown or delayed-effect cause unverified; failed press is reported rather than fabricated success | Self-care evening run one drink failure then successful retry. Dump has CanUseItem reason/cooldown/use-delay candidates, not yet verified safe or relevant | open mechanics investigation; no guessed timing workaround |

## 2026-10-27 — Transport contract follow-up

| ID | Symptom | Cause | Fix / evidence | Status |
|---|---|---|---|---|
| R18 | New tree task selects chop, then directed run raises unexpected keyword mode | Typed schema emits optional mode (including None); real BridgeClient.gather and mock adapters omitted it | Optional parameter propagated, null pruned from transport; real Executor/JSONL/Lua regression for explicit/omitted/null | reviewed;31 focused passed; full GREEN1070/5skip plus4dump checks passed; live transport remeasure next |

## 2026-10-27 — Navigation and discovery from live a124

| ID | Symptom | Evidence / cause | Status |
|---|---|---|---|
| R19 | go_to says arrived during KillZ death,29.44m wrongheight | a124trace20:57:57 +vitalsdeath/revive; move andbridge bothverify2Donly. Falltrajectory/cause unproven | coldreviewaccepted; fullGREEN1096/1skip; livepending, no fallpreventionclaim |
| R20 | Repeated craft_plan(Hatchet) says unknown_recipe with nocandidates | Matchingnativecategory existsinJSON butgenerator dropsit fromLua catalog; modelneverlookedup/listedrecipes intrace | coldreviewaccepted; fullGREEN1096/1skip; livepending; no automaticchoiceorstatic synonym |
| R21 | waitingbudget message understatesdelay thoughdaily/casecapsallowcalls | Directorreserves5requests, hourlywindow9/12 cannotadmit; wait_s helperonlywaitsfor1slot | verifiedschedulinggap; no windowreset or codechange; futurecasehourlimitmustaccountforpreservedwindow+reserve |

## 2026-10-25 evening (Shockbyte, build 26161880)

| ID | Symptom (what Luis saw) | Root cause (from logs) | Owner | Fix / test | Status |
|---|---|---|---|---|---|
| L1 | "Axtral Projection didn't get selected" ×9 (20:54) | The spell has a game special requirement (`SpecialRequirementsText` "Logging Axe", strategy `BP_USSRS_RequiresLoggingAxe`); he had no axe, so the game ignored the wheel key. Our row said `castable:true` and the failure said only "not selected". | spells | Each spell's `SpecialRequirementsStrategy` default object → `AreSpecialRequirementsMet(PC)` (the game's check; probed read-only on all 14 classes first) → row `castable:false, reason:"requirement", needs:"Logging Axe"`; the cast is blocked before any key press; not_selected says "(the game says it needs: …)". Tests: test_spells "requirement row…", "requirement blocks…", "not_selected names the game's requirement". | fixed (test_spells); live read verified (enchants → RequiresHeldMeleeWeapon, Home Teleport → RequiresClaimedBed) |
| L2 | Unresponsive about 3 min after "get out of the shelter" (20:58–21:01) | `go_to` while lying in bed: body timeout 46 s, then the executor retried; the bridge reload at 20:59 lost the in-flight command, so the brain waited the full 125 s bridge timeout, then retried again. Chat queued behind the blocking call the whole time. | broker + capability | (a) chat is never blocked behind a running tool (interrupt/queue); (b) a bridge restart fails in-flight commands at once (`body_restarted`); (c) no blind executor retries of timeouts — the result goes to the model; (d) movement while resting returns `resting` with "I'm in bed; I need to get up (interact) first". | assigned; (d) capability side fixed offline: go_to/follow/interact while lying in a bed answer `resting` {resting_in} at once; ping carries `started` + `action` for (b). Brain (a)(b)(c) fixed offline: addressed chat ends the wait (`interrupted`), heartbeat → `body_restarted`/`lost_by_body`, timeout/restart/lost/resting not retried (test_event_hygiene::test_l2a_*, test_l2b_*, test_l2c_*); verify live after brain restart + bridge_start |
| L3 | Said "Done." after picking up 2 items when asked to pick up AND cast (21:01, 21:02) | Old brain: the canned "Done." template after the last action; no continuation turn, so the cast never happened. | broker | The agent loop (results back to the model up to 4 turns) + no canned "Done." — live since the 21:04 brain restart; verify. | fixed (test_event_hygiene::test_replay_2043_shelter_plan_is_carried_through), verify live |
| L4 | Raw codes said in chat: "not perceived within 80 m", "I couldn't go to: unknown_target." | Old fallback templates spoke the tool's raw detail/reason. | broker | Removed in the new brain (21:04); verify. | fixed (no raw codes: test_unknown_target_goes_back_with_the_tools_own_argument_help, test_rule_not_in_the_body_list_fails_verification), verify live |
| L5 | Says what he'll do, then doesn't do it (21:02:56 "I'll walk closer and cast it") | Old brain: speech-only turn, no action and no continuation. | broker | Agent loop (21:04); add a guard test: a turn whose text promises an action must contain the tool call (fake-model replay of 21:02:56). | fixed offline: a talk-only first turn gets one check turn to call what it promised (test_l5_replay_2102_promise_without_a_tool_call_gets_a_turn); verify live |
| L6 | Slow replies (2–4 s per step, minutes for chains) | Each turn: 3 redundant `get_state` round trips before one tool; ~13k-token prompt; follow-ups serial; Haiku latency. | broker | One state read per turn (cached ≤1 s); immediate short ack when an action starts; measure p50/p95 turn latency in the timeline. | fixed offline: 1 state read before a tool, was 3 (test_l6_one_state_read_before_an_action); burst 0.8 s + partner counts as addressed; no live retries; effort low; context trimmed (spells one line each, no duplicate chat events). Replay p50/p90 4.25/4.50 s → 3.05/3.30 s (test_latency_replay; effort-low projection 2.35/2.60 s). Live baseline p50 5.0 s / p95 7.8 s; re-measure with tools/turn_latency.py after restart |
| L7 | `interact` on the Steel Logging Axe grabbed/targeted the Iron Pickaxe → `not_interactable` | The detector targets whatever is in front (nearest pile item), not the asked-for actor. | capability | Approach/face the asked-for actor until the detector names it; if another item blocks, say which. | fixed offline (test_skills L7): interact accepts another stack of the SAME item id; a different item in front → other sides of the item (0.9 m), then not_interactable naming it ("the game targets Iron Pickaxe, not the Steel Logging Axe"); verify live |
| L8 | `go_to` a tree id (`fol:...Tree_C_7:2`) → `unknown_target` ("target_not_visible") although `look` listed it | go_to doesn't resolve foliage-instance ids that look/gather produce. | capability | go_to resolves every id that look returns (foliage, interaction points). | fixed offline (test_skills L8): go_to resolves any perceived id (census/look, foliage included) to its position; creatures/players stay tracked actors; verify live |
| L9 | Aimed cast → `too_far` without moving closer | Aimed spells have a reach; the brain didn't chain go_to, and go_to failed (L8). | spells + broker | Failure states reach and distance (done); the loop lets the model walk closer (L3/L8). | brain side done (the agent loop lets the model walk closer after `too_far`); go_to of foliage ids = L8 |
| L10 | Slept in the wrong place / kept summoning new shelters beside an existing one; "painful" to get to sleep; stayed in bed after day | No perception of who owns a shelter; no house rules; no day/rest trigger to the model; interact aimed at the actor origin (roof). | capability + broker | Shelter owner in perception; house rules file (below); `situation_review` on day change while resting; interact uses the entrance collider (fixed 20:59, verified live: slept, got up). | brain side fixed offline: brain/house_rules.md in the persona (test_l10_house_rules_file_is_in_the_persona_and_re_read_on_edit); day change reviewed at once while resting (test_l10_day_while_resting_is_reviewed_at_once); shelter owner perception = capability |
| L11 | Client crash 20:49:34 after the pause-menu Unstuck teleport | UE4SS `push_arrayproperty` on an actor the teleport replaced. | locomotion | Unstuck disabled (move.lua v15); per-frame array reads audit for sense/combat/traverse_learn. | fixed (disabled), audit open |
| L12 | Debug-channel actions pre-empted the brain's interact ("I couldn't interact: interrupted") | The debug channel shares the body's action slot. | capability | Debug channel refuses actions while a brain action owns the slot (unless `force`). | fixed offline (test_skills L12): a debug-channel action while the brain's action holds the slot answers busy {owner: brain:<kind>}; args.force=true overrides |
| L13 | Axtral Projection really went off at 21:04:53 (server cooldown started straight after), but cast reported `no_effect`; the executor retried into the cooldown and Claude switched to chopping with only "On it." | Aimed-spell success check misses this spell's evidence (runes/cooldown record arrive later than the verify window, or the spell has no actor we watch). | spells | A server cooldown notice no longer fails at once: 2 s grace for a rune spend or LastCastTime change (= success); placed/aimed casts wait through the cast animation (12 s); the 15 s late-success watcher emits `cast_late_success`. Test: "L13: a cooldown notice followed by the rune spend is a success". The executor's retry on cast failures is broker-side. | fixed (test_spells) |
| L14 | Axtral Projection cast but not lined up: thrown at nothing / let time out (Luis saw it, 21:04:50) | Axtral enters the game's placement/aim preview (DIM_SpellPlacementMode). We aimed once at the tree's base point (ground), pressed fire once without checking the preview, then cancelled after 12 s. | spells | One preview loop for every spell that opens the preview (chosen by the game's mode, not the spell name). Foliage targets are aimed at the trunk (1.2/0.8/1.6/0.5 m), actors low (0.3/0/0.8/1.2 m), felled logs at the game's `GetMidPointWorldLocation`. It re-aims and re-reads the preview and releases only when valid and on the target; it reports `target_after`. Tests: "aimed: … re-aimed until valid…", "aimed never valid → no_valid_aim…". | fixed (test_spells); live Splinter run below |
| L15 | Splinter on a felled ash log timed out 5×: presses [menu, quick1] only, about 22 s each, never LMB (21:13–21:16) | The placed path ran the shelter's flat-ground spot search around the log; no ground spot is ever valid for a spell that needs an object. The budget was too long and nothing was said. | spells | The same loop as L14: the target first; flat-ground spots only when the game's tag talks about the ground (not flat/blocked/slope) or for a no-target placed spell after "straight ahead" was refused. 5 s budget, then Esc (never cast it badly), with the game's words ("requires log"). Sub-second clock (GameplayStatics time; the bridge clock is 1 s). Tests: "L15: …" ×4. Live 21:22: fails in 5 s, cancelled, 4 heights tried, preview 1.2–3.5 m past the log's stale origin → now aims at the log midpoint. **Live 21:3x: Splinter on BP_SplittableLog_Ash_C_2147462658 OK**: presses menu, quick1, place; aimed at the midpoint 0.3 m up; the preview was valid first time; BP_Magic_Splinter spawned at the preview; Earth −10, Nature −5; Splinter cooldown entry; the log split into Ash Logs drops. Follow-up fix: on success it no longer presses Esc into the cast animation (it waits up to 3 s for the game to leave its spell mode; test "success in cast mode…"). | verified live |
| V1 (spells demo, not a bug) | Spell demo: Windstep / Tempest Shield / Phase Dash | (verification) | spells | Live 21:27–21:35: Windstep through the keyless slot (highlight + name check + accept) took the jump apex from 1.80 to 7.38 m; Tempest Shield put its GE + tag on him; Phase Dash turned an air dash from 3.2 m snapped back into 8.4 m kept. Enchant Weapon is blocked: Claude starved at 21:25:56 (sustenance 0, no food) and the sword is in his grave. | verified live (3/4) |
| L16 | Hungry at 14 % (21:17): "I'll look for a fire to cook raw meat"; never considered the Redberry Bush 9 m away, cooking/crafting, or asking Zezima | Perception was flat and unranked; no "needs → options" view, though game data has item kinds, recipes and stations | capability | `brain/needs.py`: per pressing need (food, drink, health, rest, tool) the options from game data: carried, nearby pickups (Redberry Bush with id), craft/cook (unlocked recipes from `get_state.recipes_unlocked`, station near or a building piece with no build tool), cheapest missing ingredient, players who could help, time to empty at the drain rate; plus `Activity` (spells tied to the skill gaining XP, held actions, XP/items per min vs best). | fixed offline (tests/test_needs.py incl. the 21:17–21:25 replay; test_skills activity/drain), needs bridge reload |
| L17 | Starved to death 21:25:56 while saying "I need a fire" and asking for food for 8 min; berries 9 m away; never considered cooking/crafting/other options; after respawn he's at 18% food, again only asking | No needs→options view (L16); a survival need gets no urgency over chatting/chopping; raw meat and cabbage aren't edible, and he doesn't know what IS (data exists in item catalog + crafting). | capability (L16) + voice | L16 options digest + survival urgency in the digest (time-to-zero at the current drain); eval: the 21:17–21:25 replay must end with him eating (berries or cooking), not waiting. | assigned; capability: L16 digest shows every turn 'empty in ~N min at the current drain; at 0 it hurts until you die' + berries/cooking/Zezima (tests/test_needs.py replay) — fixed offline, needs reload |
| L18 | Said "[System: Empty message content sanitised to satisfy protocol]" in game chat (21:24:15) | Our replayed assistant turn had empty text beside its tool calls; LiteLLM replaced "" with that placeholder and the model echoed it as its reply. | broker | Empty text next to tool calls is replayed as `None`; `llm.strip_markers` removes `[System: …]` markers from model text, and `Controller.say` never speaks one (test_event_hygiene::test_l18_a_protocol_marker_is_never_said). | fixed offline, verify live |
| L19 | After respawn: "back up, waiting for your next instruction"; no mention of his gravestone with all his gear (axes, sword, shield) | The grave is only perceived within 80 m; the last death position isn't carried into context beyond that range. | capability | Persist the last death (position, time, what was lost) and always show it in the digest until recovered; go_to accepts the grave position from memory. | assigned; capability: death memory {where, when, lost items} persisted in client_io/state/last_death.json, shown in the digest until the grave is emptied, go_to target 'my_grave' at any distance (test_skills L19) — fixed offline, needs reload |
| L20 | Main reloaded the bridge at 21:46:33 with a get_state in flight (obs anomaly bridge_restart_in_flight) | Main's idle check read the brain log only; the brain's 30 s idle state polls can land mid-reload. The rule was enforced by hand, not by code. | capability | bridge_start drains: refuse (or wait ≤ 5 s) while any command is in flight or an action owns the slot; brain treats a bridge epoch change as body_restarted (broker L2b). | fixed offline (test_skills L20): bridge_start = `restart_when_idle`: restarts at once when idle, else re-checks every 250 ms up to 5 s and starts the moment the action slot, waiters and unread brain/debug commands are clear, else REFUSES (logged, bridge_status.last_restart, why); `bridge_start_force.lua` / FORCE=true for emergencies; the new instance takes over the old read offsets (mod/scripts/bridge.lua init offset) so a command written during the swap is still answered |
| L21 | Died of thirst twice (21:34, 21:44) at the start area, repeating "no water or food within 40 m, can you point me to some"; never went looking | No memory of where water, food and stations were seen (base water at ~44 m from the base, berries), and no explore primitive; perception ends at the census range, so outside it he only asks. | capability + Director | Per-world resource memory (water sources, food pickups, stations, lodestones seen, with position/time) in the needs digest beyond sight ("water seen 310 m NE at the base"); an `explore` primitive (expanding search with trail memory); the Director's map memory reuses the same store. | fixed offline (tests/test_map_memory.py incl. the 21:30–21:45 replay; test_skills explore): per-world map memory `brain/map_memory.py` (`logs/state/worlds/<w>/map_memory.json`, the Director reads the same store) fed by every get_state; the needs line adds 'remembered: Water Volume ('Collect Water') seen N min ago, D m <dir> at [x,y,z]' (drink sources from game data: prompt words vs drink item names); new `explore {about}` primitive (least-visited legs from his own trail, stops when a match is in sight); needs bridge reload + brain restart |
| L22 | Recovered the newest gravestone (fur, scraps) but forgot the first one with his axes, sword and shield (21:25 death near the base) | last_death keeps only the latest death. | capability | Keep every unrecovered grave (position, time, contents) until it's taken or gone; show all in the digest, most valuable first. | fixed offline (test_skills L22, tests/test_map_memory.py): every unrecovered death kept ({deaths:[...]} in client_io/state/last_death.json), each listed as its own 'Grave:' line most valuable first (summed item power level from data), go_to 'my_grave:<ts>' for a specific one; a Take All clears only the grave it matched (id or nearest death within 15 m); needs bridge reload |
| L23 | **Rule break (main's mistake):** while moving Claude to the dev world at 22:24:47 UTC, the new dev character ClaudeDev joined **Shockbyte** for about 40 s (at spawn, no brain running, no actions) before main disconnected it | client_boot used the static join_server.lua (server.txt = Shockbyte) whenever target == the *configurable* default; main had just made the default 'dev'. Main's new test only dry-ran, so it missed it. | main | Compare with the literal 'shockbyte'; after joining, a forbidden-server check disconnects and fails; real-boot regression tests (test_default_target_dev_joins_with_the_dev_file_not_server_txt, test_boot_leaves_a_forbidden_server_it_landed_on). Side effect: Shockbyte now has a cached level-1 ClaudeDev character state. | fixed (tests) |
| L24 | Client crashed at 22:31:35 UTC, right after the 3rd forbidden-server disconnect (a false alarm from the stalled game log, L23 follow-up); the watchdog relaunched it onto dev as ClaudeDev | Dump analysed (cdb): the crash is in the engine's garbage-collection path, called through UE4SS's hook callback (UE4SS!RC::Unreal::Hook::StartCallbackGarbageCollector) during world teardown after the disconnect, i.e. a UE4SS hook or Lua callback firing on objects being collected. The client game log stopped being written at 22:04 UTC (cause unknown). | main | Analyse the dump (cdb); find out why the game log stalls; the false alarm is fixed (boot records its join). | ROOT CAUSE NARROWED (A/B on dev, 2026-10-25 23:16-23:30 UTC): a GAME crash on the 3rd return to the front end in one client process, NOT our hooks and NOT UE4SS's script hooks. Hooks ON (main, 23:04) crashed on cycle 3; hooks OFF (hookhub A/B flag, 0 native hooks) crashed on cycle 3 (crash_2026_10_26_00_19_49); UE4SS engine hooks OFF (ProcessInternal/LocalScriptFunction/BeginPlay/EndPlay/AActorTick/... in UE4SS-settings.ini, backup .bak-20261026-L24, restored after) crashed on cycle 3 (crash_2026_10_26_00_29_48) with the SAME null+0x250 frame and the two UE4SS+0xcc7 frames GONE (they were the ProcessInternal/ProcessLocalScriptFunction detours). Last game-log lines each time: LoadMap(L_FrontEnd) complete, then 'UMainMenuUIAPI::MainMenuWidget Called but a MainMenuWidget is already registered!'. Mitigation (ops, main's files): never return to the front end a 3rd time in one process: after 2 disconnects, rejoin by restarting the client process; avoid needless disconnects (the 22:30 join/disconnect loop). hookhub stays (hygiene); watchdog now archives logs (Save-CrashLogs, worked: crash_*.logs/). MITIGATION IMPLEMENTED 2026-10-26 (offline, fake client): client_lib.ps1 counts front-end returns per process (game log LoadMap L_FrontEnd lines + logs/state/client_frontend_returns.json); with 2 used, client_boot.ps1 relaunches (stop, launch, join) instead of a target-switch disconnect or a menu rejoin, and kills instead of disconnecting at a forbidden server; watchdog boot_start shows fe_returns/relaunch; scenario_run.py + bench devrun --switch go through boot (frontend_state/relaunched helpers); tests/test_client_ops.py 33/33. Not yet exercised live. |
| L25 | T0 dev run 23:32: Summon Shelter and Eye of Oculus rejected as sensor_mismatch. The probe saw the spell go off (runes spent, cooldown started, shelter actor spawned), but cast replied runes_spent=[] / cooldown_started=false | cast's verify window closes before the server's rune and cooldown replication lands | spells | After the first success sign, cast polls until runes_spent AND cooldown_started are both present (bounded settle_s 8 s). An own-mode spell (Oculus) leaves its mode once and then polls 2 s more. The reply carries settled/unsettled; the late watcher stays as a backstop. A valid ground preview up to 4 m off the asked point is accepted (shelter 3.2 m). Tests: "L25: …" ×4 (fake world with delayed replication). Design: client-spells.md Rev 4 + Search record. | **verified live** (dev, 07:1x UTC 2026-10-26): Summon Shelter ok with settled=true, runes Astral −10 Earth −10, cooldown_started=true, spell actor at the preview; the independent probe agrees (Astral 153→143, Earth 20→10, the LastCastTime entry changed, the shelter present at landed_at). Timing: open 0.30 s, aim 0.53 s, verify 0.40 s, **settle 5.99 s** (the game's spend and cooldown replication), total 7.36 s. Two earlier attempts near the spawn lodestone failed honestly (preview `…SpellPlacement.Blocked`, nothing spent). |
| L26 | T0 dev run: Axtral Projection. A tree at 23 m was too_far (15 m reach); he walked there, and then the same foliage id "can't be seen any more"; the case budget ran out in that loop. Also spoke a raw id ("fol:BP_…") | Foliage instance ids aren't stable across a go_to (census re-indexes ISM instances), and the cast tool's reply leaks the id into speech | capability + spells | spells part: failure details no longer contain raw ids (the foliage / unknown-target sentences); the id stays in data.target. Test "L26: the detail never speaks a raw id". Stable foliage ids across a go_to stay with capability/sense. CAPABILITY PART 2026-10-26: the live cause is the server's NearbyFoliageConverterComponent (3 m) turning the instance into an actor and hiding it once he arrived 1.4 m from it (gather.lua logs the same adoption); index ids were also unstable (ISM swap-remove, per-cell component names). Ids are now `fol:<ActorClass>@x,y,z` (dm), and every tool resolves them through sense.resolve_foliage (bridge find_thing): the same instance, the nearest same-class instance within 1 m (reindexed), or the converted actor within 2 m (converted, with resolved/resolved_from); gone = why felled_or_picked/not_found. Design + Search record: docs/design/stable-target-ids.md. Tests: test_foliage_ids.lua (18), test_client_bridge "L26: ...", test_gather §14. | spells part fixed offline; ids fixed offline (capability), live check pending |
| L27 | T0 dev run latency: chat→first action p50 ~4.2 s (worst 12.8 s); the cast tool takes 4–7 s per call | Broken down (autonomy-plan §2a): companion heard→tool p50 ~2.1 s (effort low applied); worst = the session's cold first model call 11.2 s (litellm import 5.8 s + TLS + first cache write); ~2.2 s of the bench figure is its own observer probe (t0 stamped after the before-probe) | broker + spells | spells part: data.timing per stage {open, pages, select, aim, verify, settle, total, page_turns}. Cuts: the short page direction (M.page_of from slice icons; up to 2 turns, about 0.9 s), page polling at a 0.1 s minimum (was 0.4 s), and the fixed 3 s post-success wait replaced by the settle poll. Tests "L27: …". | brain: fixed offline: Controller.warm_up() at session start + local litellm cost map (test_l27_*; replay first line 11.65→2.15 s); effort logged per prompt. Bench: devrun must call warm_up; observer t0 before probe. Cast route 4–7 s = spells |
| L29 | After Eye of Oculus (evidence probe, 07:2x 2026-10-26) Claude stayed stuck in DIM_OculusBuildMenu; Esc / IA_UI_GenericBack did not leave it, and every following cast failed with wheel_not_opened | The cast's cleanup only knew the spell keys (Q / Esc). Esc moved him deeper into the Oculus build menu, and CommonUI's back action does not take injected input | spells | M.MODE_EXITS (data from the dump: UOculusComponent IsOculusActive / RequestExitOculusMode, the build legend's Exit). Once settled, the cast leaves an own mode through that handler and waits for DIM_Gameplay (leave_s 2.5). Cleanup does the same on failures, and a cast that starts inside an own mode (left over, or after a pause) leaves it first. Tests "L29: …" ×3. Live: RequestExitOculusMode took him from DIM_OculusBuildMenu to DIM_Gameplay. | fixed offline (test_spells), deploy pending |
| L30 | After the input.lua modal gate landed (build review, 2026-10-26), every cast failed "not_selected" and the wheel stayed open (caught live by the spells agent at 08:1x on dev, Oculus / Stone Spirits) | spells pressed through combat._inject, which is now gated by input.lua; the open wheel is a non-gameplay input mode, so every press after Q (and the Q that closes it) was refused. test_spells stubs W.inject, so no offline test saw it | spells | W.inject goes through input.inject(action, nil, {modal = "mode"}): spells owns the 'mode' modal, while build-mode and container modals still block it. A cast that meets a blocking modal answers busy ("I can't cast right now: build mode is open."). New integration test client_mod/tests/test_spells_input.lua drives a full cast with the REAL input.lua (instant and placed casts pass; build mode and a container screen block with nothing injected). | fixed live (inject); integration test + busy reason staged |
| L31 | Director smoke run 1 (dev, 08:46): the model's content "EMPTY" was SPOKEN in chat 3×; "hey! what we up to?" opened unprompted board runs twice | The persona's empty-reply convention leaked as literal text; board-run turns are treated like greetings | broker + voice | Treat the sentinel as silence (like L18); board_step runs speak only results that matter; test. | assigned |
| L32 | Smoke run 1: hydration fell to 18.7/75; the stay-fed reflex's Clean Water use FAILED and he had no other drink | Root cause: the reflex pressed Clean Water mid-gather at 07:48:00; the use didn't take, and R.bad marked Clean Water bad PERMANENTLY after one failed verify, so he never drank again (hydration 0, HP 20 by 07:59). Not the gate. | capability | FIXED offline (inventory.lua): strikes. An item is given up only after `bad_after` (3) failed uses in a row; a success clears its strikes; retries are spaced by the per-kind cooldown. The reflex goes through the real input.lua gate (talk finding 11). Tests (test_inventory_reflex): 'L32: retried after one miss and drank'; a no-effect drink given up after 3; real-gate integration (conversation open -> no press; gameplay -> drinks). Live check pending (deploy in the capability slot). | fixed offline |
| L33 | (Found in review, live body) With talk disabled, interact on an NPC opens a dialogue that nothing closes, so every gated action is refused and Claude is trapped | interact's new conversation press-signal stops re-pressing but has no exit path while talk is off | capability | Leave with the panel's Cancel and say why; integration test with the real input.lua | fixed, live 08:21 UTC (test_skills 44, test_input 25) |
| L34 | Dev parry trial 2 (09:34:37 UTC 2026-10-26): he stood still facing a Kebbit spawned 5 m away behind a wall. The attack timed out after about 2 min with a bare `timeout` and nothing said | combat's approach only restarted the follow when it stopped; it never read move's verdict. move logged `unreachable: no_route` at 09:35:27, 50 s in, and the fight ran on to `fight_timeout_s` | combat | `combat.approach_blocked`: (a) move's own verdict (follow `status = unreachable` + reason) ends the fight at once; (b) no progress (0.5 m closer per 12 s) ends it. Either way the result is `path_blocked` {why = no_route / target_above_jump_height / wedged / no_progress, target, dist_m, walls, move.lp_fail/stuck_n, detail "I can't reach the Kebbit: there's no way through to it from here."}; `path_blocked` added to attack's MANIFEST reasons. Tests: test_combat "wall: …" (no progress, ends < 16 s), "unreach: …" (move's verdict, < 1 s). move.lua is unchanged (it already reports the verdict). **Also covers the 2026-10-25 22:01:38 and 22:03:41 `attack` 120 s tool_timeouts** (Shockbyte, a Kebbit on a ledge 2.7 m up: move said `unreachable: leader_above_jump_height` at 22:02:33 and 22:03:02, and the fight ignored it). Added for a target that keeps moving: a chase budget (30 s of approach without a landed hit) and a stall while the target itself moved > 3 m give `too_far` {why = cant_catch, chased_s, target_moved_m, detail "I chased the Kebbit for N s and couldn't get close enough to hit it (it keeps moving away)."}; `leader_above_jump_height` is worded like `target_above_jump_height`. Tests: "ledge (22:01 replay)", "chase: …" | fixed offline, verify live |
| L35 | Claude's client went DOWN at 10:55 UTC on 2026-10-26: after the Eval agent restarted Steam (`steam -shutdown`, then `-silent`) for the Steam Cloud change, Steam sat at its login screen (ActiveUser 0) | bootymaxer was never logged in with "Remember me": config/loginusers.vdf was empty and HKCU AutoLoginUser/RememberPassword were blank. The earlier login was typed by hand, so a restart cannot log back in by itself. Nothing checked this before the restart | eval (tooling) | `tools/steam_restart.py`: refuses (exit 3, touches nothing) unless loginusers.vdf lists bootymaxer with RememberPassword 1 AND AutoLoginUser = bootymaxer; `--check` reports only. Tests: tests/test_steam_restart.py, including the exact 10:55 state. Rule: never restart Steam by hand; use this tool. Recovery needs a person: Luis logs in over RDP and ticks "Remember me" | guard built; login pending (Luis) |
| L36 | go_to false failure (live 22:19:34 on 2026-10-25, episode 221904b): the executor `_v_go_to` checked arrival in 3D while the body checks on the ground plane. A Water Volume surface point 3.1 m below the ground read as "still 3.2m from target". That drove 4 retries, an explore loop, and a template that read the metres into chat. | Fixed offline: arrival is checked on the ground plane plus a 4 m vertical bound (another level still fails truthfully); the VERIFICATION_FAILED chat phrase no longer carries metres. tests/test_arrival_check.py. Verify live. |
| L37 | Claude's client crashed at 14:56:19 UTC on 2026-10-26 during a Director `explore`, as the first fight of the session started (a Giant Rat, flee on low HP). pid 7080; dump `crash_2026_10_26_15_56_19.0234266.dmp`; the watchdog relaunched it and it booted ok at 14:57:10 | **Ours: a stale UObject held across ticks.** cdb: AV reading `0x00025dc2…0895` in `UE4SS!UStruct::FindProperty`, reached from the UObject `__index` metamethod in a Lua hook callback (`Lua::call_function` ← UE4SS hook trampoline ← game). That is a property lookup on an object whose class pointer is garbage. `combat.on_ai_action` (the new `Multicast_StartAIAction` hook) stored the raw `comp`/`owner` refs in `c.ai_actions`. Nothing resolves or prunes those records outside a fight (`ability_frame` runs only in fights; the ambient tick is off by default). For about 3 min of explore he sprinted past Kebbits and chickens, which despawned and were GC'd. The rat fight's first `ability_frame` read `r.comp.CurrentAction` on 12 records (client.log: twelve "ai action … on Kebbit/Chicken: ?" lines at 14:56:19.014–.020) and the 13th was freed. The crash came 3 ms after the last line. Not OOM: the AV is in property lookup, not an allocator, and there is no "out of memory" in RSDragonwilds.log (the minidump has no memory map). No known engine/UE4SS issue applies: UE4SS `IsValid` is safe on freed objects (it checks the live-object set), but `__index` is not. | combat | The hook keeps object **paths**, never refs. `ability_frame` re-finds them (`U.find_object` + `U.alive`; nil once the object is gone), never resolves an action older than `cfg.ai_action_resolve_s` (3 s), and prunes on insert. Foundation: `U.loc` checks `U.valid` first, because `F.target`/cached actors reached `U.loc` unguarded. `ranged.muzzle` validates its cached comp. Test: test_combat "stale: …" ×4 (a freed fake records ANY access as the AV; the old code fails with `CurrentAction,CurrentAction`). All client_mod and mod suites pass. Audited: `c.boss_lvl` (U.valid before each read, safe); hazard actors (fresh `find_all` per census); census `_comp` (stripped before the wire, never read across ticks); `find_creature` (validates its census cache). | fixed offline (test_combat stale ×4); needs a client restart; verify live with a fight after a long explore |
| L38 Repro 2026-10-26 20:24 and 20:25 (local; dumps 20_24_07, 20_25_57): 2 of 2 crashed. | Claude's client crashed twice on 2026-10-26, each time on the pond bank with water low: 17:08:10 UTC (pid 8620, `crash_2026_10_26_18_08_10.7494398.dmp`) and 17:26:17 UTC (pid 7900, `crash_2026_10_26_18_26_17.9744489.dmp`, during collect_water's wade step). The "client HANG" stack at 17:18:07 (`logs/client/hang_8620_20261026_181807.txt`) is **the 17:08:10 crash**: the same frames, with the GameThread parked in UE4SS's crash MessageBox (risk R2) | **ROOT CAUSE (2026-10-26 evening, DISCOVERIES "Client crash L38"):** with `-nullrhi`, FApp::CanEverRender() is false, so every Niagara spawn returns NULL on Claude's client. Verified live: `SpawnSystemAttached` gave NULL with and without pre-cull, and the shipped `CreateNiagaraSystem` bails out on that check. `ADominionPlayerCharacter::AddNiagaraSystemAttachedWithLocalTag` stores the NULL in `LocalFX` without a check. The trigger row is `TaggedLocalNiagaraSystems[Environment.SoulScourge]` → `Player.Vfx.SoulScourge` / `NS_SoulScorge_PlayerEffect_Buildup`, which Dirty Water's +20 Soulscourge sets off. `RemoveNiagaraSystemWithLocalTag` (exe+0x64AEAE0, inside the tag-changed broadcast) then calls Deactivate on NULL: the AV at +0x2C0. The watcher saw `LocalFX={Player.Vfx.SoulScourge=NULL}` with no component created, one frame before the crash. All 8 dumps are identical. Earlier analysis, kept for history: **Game code, set off by the stay-fed reflex drinking Dirty Water.** Both dumps show the same AV: a null read (`mov rax,[rcx]` with rcx=0, then a virtual call at +0x2C0) in game code. The receiver is Claude's own pawn (`BP_PlayerCharacter_C_2147473177` on 17:26: the FName in `[rdi+0x18]`). The code looks the pawn's map at +0x1748 up by a handle and calls a virtual on a null result. It runs inside a multicast-delegate broadcast during the world tick, under UE4SS's engine-tick detour. **No Lua frame**, so it is not a hook callback or a stale ref. **The trigger is the same in both:** vitals.jsonl `reflex use drink ITEM_Consumable_Water_Dirty` at the safety floor (17:08:10 hydration 0 and hp 1; 17:26:17 hydration 7.5/75 = 10 %, via hotbar key 8 and key 1). The game log then shows `HandleSlotUseEvent QuickAction Slot N` → `PrepareForItemUseDelay`/`StartItemUseDelayTime` → `RequestAsyncLoad() … null assets`, and the dump is 150 ms later. Today 2 of 4 Dirty Water drinks crashed (16:55:22 and 16:58:41 did not, one of them in the water); 0 of 31 other consumable uses did (Clean Water 7, Redberry 16, Anchovies 5, Bread 3). Not wading: water_wades is not on the 17:08 path, the 17:26 wade was only the setting, and a drink in the water at 16:55 was fine. Not the 17:22 bridge_start code: the 17:08 crash predates it. Not the Soulscourge threshold: 20 per drink, damage only at 100 (wiki). The headless `-nullrhi` client is suspected but not proven. **Separately, the watchdog lost 10 min:** at 17:08:19 it saw the dump but was `restart_rate_limited` (3 per 30 min, counting the 16:51 and 16:57 `client_gone` exits), so the crashed process sat in the MessageBox until hang detection killed it at 17:18:15. | capability (vitals reflex) + ops (watchdog) | **FIXED (mechanism):** `client_mod/scripts/fxguard.lua` (client_bridge service `fxguard`) empties `TaggedLocalNiagaraSystems` on every player character on Claude's client. The tag handler then never stores or removes a NULL, whatever row it is. It is cosmetic and client-local. Verified: 3 Dirty Water drinks in a row on one process, no crash, LocalFX empty, the status GE applied; offline test test_fxguard.lua 14/14. PROPOSED, for main to decide: remove the Dirty Water crash guard (the `ITEM_Consumable_Water_Dirty` entry in data/consumable_risks.json; the generic `crash_refusal` rule in inventory.lua/skills.lua can stay as the mechanism for any future crash item) once fxguard is in the committed bridge, and update test_inventory_reflex/test_skills to match. At-risk siblings (other NULL-VFX holders, e.g. UTagActivatedFX, AHeldEquipmentActor enchant FX, DrainEffectManager, DetectOre) are listed in DISCOVERIES. The watchdog rate-limit item (2) is unchanged. | fixed (root cause found; mitigation live; crash guard removal proposed) |
| L39 | (Found reading the 16:58 log) "ai action … on Kebbit: DAA_Kebbit_Breathe_01_C (breath_cone)", and the same for `DAA_Deer_Breathe_01_C` | `ability_profiles.lua` matches by substring and orders "Breath" before "Idle", so the creatures' idle **Breathe** animation reads as a dragon breath: threat, unblockable, 18 m reach. In a fight that is a dodge (`_start_defend`) and a false `creature_ability` event for every breathing Kebbit or deer. | combat (data) | Data-only fix: add a `Breathe` token → `{ kind = "idle" }` ahead of `Breath` in `order` (or match `_Breath_`). Test: `ability_profile("DAA_Kebbit_Breathe_01_C").kind == "idle"`, with Vel'gar's PoisonBreath unchanged. | fixed 2026-10-26 (general): `combat.ability_profile` matches tokens and sides as WHOLE WORDS (`combat.words`: split at `_`, CamelCase, acronym and digit boundaries; `has_words`: contiguous word run), so no token matches inside a longer word (Breath/Breathe, Idle/Idler, Death/Deathless, Front/Frontflip); `order` now only ranks tokens that both match (PoisonBreath before Breath). `Breathe` kept as idle data, deliberately ordered after Breath. Audit: every DAA_ class in dump 26161880 resolves to its intended kind. Tests: test_combat §10d2, 25 new checks (incl. a stub table with no Breathe entry), 381/381 pass. |

## House rules (Luis's explicit rules → given to the model, not code vetoes)
Lives in `brain/house_rules.md`, loaded into the persona; Luis can add lines.
- Sleep in your own shelter. Don't use another player's shelter or bed unless that player asked you to.
- Get up and out of bed as soon as it's day.
- (PvP is off: never attack players.)

### B-stuck-focused-ui (FIXED 2026-10-26 19:17 UTC, live on ClaudeDev)
- **What happened:** the PC stayed in DIM_FocussedInGameUI with no visible screen. It blocked the spell wheel (`wheel_not_opened`), the stay-fed reflex and every input-gated press.
- **Root cause:** a Campfire (processing station) craft. On exit, `crafting.W.close` called `CraftingUIAPI:HideCraftingUI(15)`, which is a no-op for the Processing panel. The game's `InputManagerUIAPI:IsOpen` still reported Processing (15) and its coupled Inventory (11) as open, with `CurrentlyActiveWidgetForController = WBP_Inventory_MainPanel_C`. Both occurrences followed such a craft: 18:35:38 (the bread at 18:43 came later in the same client process) and 18:59:18. The failed bread consume was a coincidence.
- **Fix:**
  - **The game's own close:** `InputManagerUIAPI:CloseWidgetIfOpen(PC, 15, false, false)` closed both widgets, and the mode went to DIM_Gameplay at once (live).
  - **crafting.lua:** `W.close` uses that close (`input.close_screens`), and the craft claims `"screen"` while its menu is meant to be open.
  - **The general guard, input.lua:** a new modal kind `"screen"`, meaning a menu input mode while the game reports an M.SCREENS widget open. It is swept when unclaimed, and `input.after_action` runs from `client_bridge`'s finish of every action. The stay-fed floor may also leave it.
  - **lodestone.lua:** closes its map the same way.
- **Live verification:**
  - A Clean Water craft at the Campfire logged `crafting: closed [Processing]` and left the mode at DIM_Gameplay. The reflex drank the Clean Water in the same second.
  - An Inventory opened by hand was closed by the guard after a `go_to`, and again by the orphan sweep.
- **Probes:** `client_mod/commands/widget_open_probe.lua` (IsOpen for every screen), `ui_close_widget.lua`, `ui_open_inventory.lua`, `input_gate_once.lua`.

## 2026-10-26 M4/M5 offline audit (mock: GearWorld + the real Sonnet Director's first decisions; 25 Sonnet calls)

| ID | Symptom | Root cause | Owner | Fix / test | Status |
|---|---|---|---|---|---|
| A1 | Mining job: the plan mined a resource that wasn't near him; only 10 ore, 1 trip | The Director's snapshot (`_compact_state`) dropped `nearby_resources`; open amounts became token passes | brain (director) | `me.resources_near` + prompt rules (open amounts, loop order). Re-recorded: the nearby kind, 30 ore, `trips_at_least` 2. Test: `test_the_planner_snapshot_shows_what_he_can_gather_here` | fixed offline |
| A2 | Mob-drop job: after ONE pass of the kill loop, the step planned after the loop ran | `requeue_loop` appended the next pass to the END of the step list | brain (board) | The pass is inserted after the group's last step. Test: `test_a_loop_pass_is_queued_before_the_steps_planned_after_the_loop` | fixed offline |
| A3 | Mob-drop job: the weakness was found (wiki "weakness: Fire") but not used: "can't confirm he can cast it" | `get_state.spells` was not in the Director's snapshot; the fight-prep rule covered only `risk` steps | brain (director) | `me.spells` + a rule to use the weakness on every kill step. Test: `test_the_planner_snapshot_lists_his_spells_for_prep` | fixed offline; real-model recheck pending |
| A4 | Quest chain: no prerequisite job for Goblin Diplomacy (it requires Rune Mysteries) | `Knowledge.lookup("Goblin Diplomacy", kind=quest)` returned lead and Rewards without Overview requirements | brain (knowledge) | Structured-fact ranking implemented before recovery; tests/test_knowledge_infobox.py::test_quest_lookup_returns_the_requirements verifies lead + Overview | fixed offline; autonomous quest-chain recheck pending |
| A5 | Quest chain: `go_to "Bramblemead Valley"` (a wiki region) with no coordinates; the NPC is too far to perceive | Named wiki locations lacked a world-position resolver | capability | brain/places.py resolver and game map data implemented; test_real_data_resolves_bramblemead_valley plus province/NPC tests pass. Recovery regenerated all 31 game region tags | fixed offline; end-to-end travel/quest recheck pending |
| A6 | Mob-drop job: "keep them at home" with no home or chest yet → `go_to "home"`, and a store step into a chest that doesn't exist | Planner error (no home place, no storage). The new prompt rule makes it build or find the store. Its recheck: the done test was still only a tally, with no storage buildable in that mock world | brain (director) | Prompt rule; recheck on dev | partly fixed |
| A7 | (mock gaps, not companion bugs) BenchWorld can't play any M4/M5 case: no scene for `fresh_dev_v1`; no referee built / container / planted events; no XP; no quest log. GearWorld: attacks have no damage type and enchants change nothing; NPCs are not in `get_state` (interactables) | Mock coverage | harness (evals, brain/mock) | Measure on dev; or extend the mocks | open |

### R25 — Direct compound request ends at local chain ceiling (2026-10-28, candidate in progress)

On528ae99, `brain-live-20261028-004716-9716.jsonl` ended with `chain_stopped turns=4 why=budget` after successful gather and consume. Five Haiku calls, no planner calls, no model completion, no pending goal, hydration still0; finite private harness then stopped. This is the per-chain ceiling, not the daily/provider cap. The model's exact last results/context need a bounded later continuation rather than silent loss. Continuous-production follow-up via other events remains unmeasured. Independently reviewed design `docs/design/controller-chain-continuation.md`; source candidate in W only, not deployed or live-proven. Preserve chat preemption, exact result IDs, body ownership, budget and directed-board contracts.

R25 update: bounded in-memory direct-command continuation implemented, cold-reviewed and full-gate verified1156/1skip. Per-action/event/identity/budget revalidation, exact call IDs and partial-turn snapshots preserve completed work through ambient routing; newer addressed work owns the reply. One additional four-continuation-turn slice and300s monotonic ceiling remain explicit resource limits, not proof of task completion. Directed-board behavior unchanged; async budget cache freshness hardening remains deferred. Native/deployment-model validation is next.

### R26 — KillZ on a remembered death-position route (2026-10-28, open)

Unassisted a388 pilot moved to `my_grave:1793134678`, resolved to old death position[89.18,1682.47,-72.13], not a verified current grave actor. Fatal replicated DamageComponent info names KillZVolume at00:26:58; death then native revival00:27:05. Last local path ended at sampled[92,1726,-17.63]; later straight sprint steering was not continuously forward-floor guarded. Exact loss-of-support point and collision/streaming/terrain cause remain unestablished. Prior3Darrival repair correctly reports companion_down and is not prevention. Preserve dev nav_memory r108/r32 and last_death; do not hard-code a grave blacklist or repeat the fatal route. Next: existing forward-floor-integrity design and read-only native floor/level evidence. Private audit records actual Epic FindFloor/FFindFloorResult/WorldSettings/streaming search and source findings.

R25 native status: a388 developertrace verified6successfulactions but exposedmissingepisodeonthesixth. Source6da33fe fixes that and passesGREEN1157/1skip; current-code developer-v2 repeats6successeswithcorrectcapture/rawtraceagreement andoriginalepisode. This verifies boundedcontinuationmechanics underdevelopercontrol, not Haikucompound-taskcompletion. The subsequentHaikutrialendedbyR26KillZbeforecontinuationboundary; R26 remainsopen.


### R26 sensor finding — packed output Booleans (2026-10-28)

The installed UE4SS struct-to-table output copier uses an unmasked Boolean conversion, whereas reflected UScriptStruct member reads apply the field mask. Current-location FindFloor output table reported line-trace/penetration=true against CurrentFloor=false. One independently reviewed typed posthook current-position observation matched native reflected bits and numerical geometry; all copied packed flags remain unknown. No upstream binary/memory patch or production guard was made. Older Distance==0 penetration advice is superseded. Full evidence/limits: [R26 observations](research/r26-floor-observations-20261028.md). R26 stays OPEN: future-position reads, safe-runway/release measurements and generic guard/live remeasurement remain unfinished.

R26 measurement update2026-10-28: nine typed offset queries succeeded; one-input developer pilot stopped after1.39cm with HP100. Diagnostic plumbing is verified; continuous support and representative braking remain open. Requested50ms timers produced66.67-120.96ms gaps. Latest113-check sampler adds input/release velocity recording, not yet live. Do not infer the fatal terrain cause or prevention from this pilot.

R26 source checkpoint: disabled floor_read utility is implemented, full gate1158/1skip GREEN and one stationary caller-specific read verified. A12-input walking trial completed at450cm/s release with7.399cm horizontal post-release; only one slope, no sprint/general envelope. Earlier8-input result remains partial after observation cost overrun. Continuous support is still NOT integrated. Phase audit found jump/spell side effects before the final input point and separate combat/gather inputs; prevent an overly broad coverage claim. Preserve unknown-vs-obstacle distinction and avoid learning unknown observations as traps.

### Guarded execution can confuse held time with a movement stall

Publishedb13793e normalramp replay failed45s belowrequestedfloor. Firstmemory
entry25cm away, earlysampledcorridorclear, later memoryloss/nativepartial/water
replan. Syntheticstationaryentry reproducesguardedstall mechanism; actualinitial
inputcause remainsunproven. Currentstalltest precedes pendingguardtimeexclusion;
latchedclock can also charge preinputcallbacktime. Narrowcandidateafterclear and
ownedinputfirst-observationanchor underreview; no tolerance/watermap workaround.
Discoverywithoutoperatorroutes and self-suppliedwater remainopen. Clientwas
closedat59HP/dehydration0 afterfixturesranout, noautonomouspassclaimed.

### Coarse ground-following chord rejects traversable terrain

Fresh native capsule query blocked, but real ordinary input from the identical
pose crossed alive/grounded. Native midpoint support plus two full-capsule sweeps
validated a different ground-following polyline while retaining the old block.
Bounded adaptive candidate passes stationary native replay and focused negative
controls; full deployment/live acceptance pending. No capsule shrink or hit-ignore.
Fresh-route discovery remains separately blocked by partial-NPC selection gating.


### Guarded memory waypoint oscillation discards route (2026-10-29)

OPEN, measured on `ccfd357` developer return a812. First memory waypoint is
26.55 cm away; observed positions bracket it while its index stays 1. After
1.0028744 seconds of admitted-input exposure, net displacement is 19.1553 cm
against 50 cm threshold, causing `guarded_stall` despite a clear corridor.
The dormant partial native path takes over next tick, then fails support.
This rules out complete-native replacement and binding invalidation as the first
cause in this run. The outbound a810 passed, so the earlier failure is not
assumed deterministic. See design/guarded-waypoint-crossing.md for the bounded
sample-crossing hypothesis, guard-preserving candidate and adversarial controls.
No radius inflation, temple rule, model steering or autonomous success claimed.


### Local walking loses progress credit before pending guard returns (2026-10-29)

OPEN on full-agent `1ba76d5` a811, generations10/11/12. Each actual local route
advanced approximately12-13m through successive waypoints/windows, but prog_pos
remained at the start. All ended `local route unavailable`; final progress-clock
ages approximately2.6s fit the existing self-stuck backtrack test. The invalid
selected source is inferred from source and timing, not directly stamped by the
current invariant trace. Audit early physical credit before guard-pending/prefix
returns and recovery ownership. The preserved feedback-loop candidate has relevant
early-credit hunks, but its unrelated route-selection changes must not be imported.


### Current autonomous exit: clear guard, real stall, then lower partial route (2026-10-29 22:32 UTC)

OPEN, measured complete-agent a821/35d8d61. Generation4 memory waypoint13 admits1.0205s input but observes only8.43cm displacement near [69.35,1872.09,-33.10], aiming [71.78,1869.53,-31.46]. Guard reports sampled_corridor clear. guarded_stall discards it, fresh partial native/local routes run, then floor_not_walkable. This is distinct from the repaired lost-progress bookkeeping and the exterior226m side collision. Actual input vectors/velocity/contact during this stall were not captured by the one-Hz full-agent observer; don't infer a particular collider or unsafe memory connector without the next diagnostic.

### Empty board run erases real failures from Director feedback (2026-10-29)

MEASURED a811 model boundary: three movement failures reached Haiku in calls21/22. Empty board run then overwrote _last_results with []; Sonnet call23 saw only predicate no-progress. Current-attempt step.actions retained the raw results. First-call feedback also omitted route_feedback. Candidate in design/attempt-feedback-retention.md uses bounded current-attempt evidence, clears on new attempt, and preserves supplied metadata without invented freshness. Focused12/design5 pass; cold review/full gate/deployment/live proof pending.

### Acceptance wrapper stops on recoverable local planning wait (2026-10-29)

OBSERVED a821 ends waiting_budget after15responses, below its40-call/900s bounds and below shared dollar cap. Sonnet had constructed an alternative plan but it had not executed. Inspect production wait/resume semantics and wrapper termination contract before treating this as permanent task inability or starting another acceptance episode. Do not inflate budgets or erase no-progress history to hide the wait.

### Long native leg enters recovery despite physical advance (a828, 2026-10-29)

MEASURED on35d8d61 developer replay, generation8: complete native five-point
route selected after memory scan_timeout. While targeting waypoint2, progress
position remained[9074.010,180561.706,-2970.022]cm. At no_progress_bug2 the
pawn was[10623.019,180730.678,-3040.091]cm,15.582m away from that baseline,
with a clear sampled guard. The operation eventually hit its120s deadline.

Read-only retained segment has start[8760,180527,-2998], endpoint
[13312,181024,-3030], high409.460cm, mark315.922cm and half-height88cm.
The segment helper requires feet within65cm of a linear endpoint-height
interpolation. Exact predicate reconstruction is the next diagnosis; do not
claim the live trace directly stamped that rejection or enlarge the tolerance
without a reviewed floor-safe design. Earlier 3cm splice stall is timing
sensitive and was not reproduced by the bounded private motor baseline; it
remains a separate unresolved issue, not a proven permanent obstruction.

### Grounded line-fallback floor rejected by fixed 5cm sensor limit (a830)

MEASURED on deployed35d8d61: developer return failed sensor_unavailable after
27.438s, health100. At the stopped pose, ordinary walk_sense.acquire reproduces
preflight:shape_or_collision. Native CurrentFloor is valid, blocking, walkable
and line-derived; pawn is grounded. LineDist=6.142799cm, FloorDist=0.260828cm,
capsule34/88cm, MaxStepHeight45cm, Player profile and empty ignore arrays.
clearance() selects LineDist and rejects values above5cm. sampled_ground_walk
also has an independent fixed5cm starting-floor bound. Choosing FloorDist
instead or changing only the first limit is not a demonstrated repair.

Exact historical acquisition detail was discarded by walk_guard's pcall
wrapper; current stationary reproduction identifies a real present blocker,
not every prior sensor_unavailable occurrence. Separate bounded design audit
is underway. Evidence: private lpc-trial-a819/decision-a830.json and its linked
raw results. No autonomous pass or floor-limit relaxation is claimed.


### 2026-10-30: blocked partial native route prevents local recovery
Observed on a98de42: a832 memory proposal included an unwitnessed r95→r14 connector through a side wall. Guard rejected it correctly; fresh partial native path also hit a side surface. Since `st.path` existed, strict local observation was skipped, and nonmemory guard failure ended the command. a837 additionally demonstrates the legacy short-route local→memory authority switch; it does not test strict local recovery. See private a832 navigation-audit and a834/a837 decisions. Repair under design review; no live fix claimed.

### Supported straight chords reject a grounded descent (2026-10-30)

MEASURED: actual a848 grounded movement crosses; a849 sampler from same observed
start rejects final descent. a850 finds all actual positions collision-clear,
while the descent chord blocks; deferred horizontal/down sweeps both clear.
a851 full short segment clears with only descending alternative and existing
rise refinement. This rules out blanket shape/profile disagreement for these
poses; exact native internal StepUp invocation remains unobserved. Do not mark
this edge unwalkable or promote the parked fullcapsule graph-edge invalidation.
Repair must preserve query accounting, explicit swept polyline, floor, lifecycle
and cache checks. See design/grounded-step-sweep.md. Not yet live repaired.

Follow-up on `6cade13`: developer a867 exercised the repaired descending
primitive and reached the lodestone. This closes that diagnostic reproduction,
not general navigation acceptance. In a869 the later local-plan collision is
reproducible with captured scan geometry and remains blocked when raised through
the measured step-height range (a870). Preceding memory stall audit found no
observed waypoint crossing or adequate movement under input. Do not weaken
thresholds or treat this as another proven descent mismatch. The exact cause of
a later3.95m idle-position change is unrecorded; bridge history has no new go_to.
See private `npg-trial-a832/stall-a870-review.md` and `collision-a870.json`.

### Routine review competes with pending Director planning (2026-10-30)

Verified full-agent a873: after generation6 route failure, Sonnet replan call6
started; Haiku situation-review call7 independently retried the same destination.
Later a hydration review called `pause_board` while another replan was pending;
the completed Sonnet plan32 was discarded because the task was now paused.
`Agent._review_tick` checks `Director.running` (only `_in_run`), not pending
planning, and `flush_situations` has no equivalent planning guard. Defer and
revalidate ordinary reviews while preserving urgent situations and human
interrupts. Do not disable stale-plan rejection or rewrite model-selected actions.

Separate provenance defect: the internally generated pause is recorded as
`player:Luis`. Luis did not pause this trial or the development Goal. Preserve
the original trace and distinguish model/internal event origin in the repair.
Private proof: `full-agent-a873/perception-feedback-audit.md`, actual input/output
calls6/7/31/32 and session log `brain-live-20261030-021349-14184.jsonl`.

### Retrying final goal discards useful away-first exploration (2026-10-30)

OPEN on6cade13. A879 walked to sampled candidate [52,1907,-31.168] with H100,
then a880 normal final-goal retry navigated back to the same disconnected basin
and ended route_ended_before_goal/verify_exhausted. This rules out a simple
away-first nudge followed by unchanged retry as a sufficient repair. The sampled
endpoint is not yet proven a route to the goal. Need generic observed-frontier
selection and retained outcomes; no task-specific route or hidden hints.

Scheduling race candidate published08f2f6d after GREEN1345/1; live closure pending.
A883 confirms the reached away point supplies179additional observed columns, but
the ordinary goal-directed planner still fails. Observation/attempt continuity
and explicit exploratory selection remain open; there is no autonomous pass.


### Complete agent still returns to a failed navigation basin (2026-10-30, a885)

OPEN. With two Director replans applied on08f2f6d, the complete agent still never acquired the starting lodestone. Its lexical ramp exploration walked53m but the next original-goal retry returned to the failed ledge. Replanning ownership alone therefore does not solve navigation. New bounded terrain observation/history candidate remains unproven until developer and complete-agent live tests.

The final pause_board call was model-originated, yet task07b319e8 records player:Luis. This provenance bug is still OPEN; it must not pause the development Goal or be reported as a user cancellation. Retain history and use supported operations for a fresh trial. Evidence: private full-agent-a885.
