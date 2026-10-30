# Discoveries

### Temple ramp supports normal player walking; route choice was wrong (2026-10-29)

Default NPC navigation from the demonstrated approach steered behind the ramp
and failed below the requested floor. Real client input along the human's actual
line climbed4.2m in3.135s, then crossed the upper doorway in3.88s, health100.
Developer-selected travel reached207m from lodestone and returned by real controls;
nutrition fixtures and steering were declared, so this is not an autonomous pass.
Saved route records r126/r127 are useful experience with developer provenance.
Do not infer that the blocked behind-ramp sweep was itself a false collision:
it tested a different segment. Private wt-trial-a716 retains actual traces.

### Native floor search origin affects support visibility (2026-10-29)

On this client/build, historical support queries over one flat floor returned
walkable hits at distances43.18-47.29cm but a no-hit at the next raised origin,
with returned FloorDist47.4001cm and both blocking flags false. Exact segment
was independently traversed through normal character input while grounded.
Interpolated nav height was the query-origin error, not a demonstrated wall.
This is a measured local case, not a universal FindFloor range constant or proof
of temple exit. Adapted source references sit beside the sampler; details and
actual primary-source searches are in research/2026-10-29-player-grounding-native-controls.md.

### Historical citation correction (2026-10-29)

Opening https://github.com/UE4SS-RE/RE-UE4SS/issues/484 during the inline-source
audit found a DWMAPI loader report, with no UnregisterHook match. The older
hookhub/recovery claim attributing function-dependent hook crashes to that issue
is unsupported. hookhub comments now preserve that attribution as historical
and link the actual upstream lifetime fix and later transition-crash report:
https://github.com/UE4SS-RE/RE-UE4SS/pull/1010 and
https://github.com/UE4SS-RE/RE-UE4SS/issues/1351.
Those sources establish upstream reports, not our native crash's root cause.

### DEV local barrier reconstruction (2026-10-29 10:32Z)

On published65af2cb, three candidate edges rejected by localplan were reproduced
with Player-profile rays at knee and higher heights: both hit normals with
Z near0. Their endpoints yielded native walkable floor results; those endpoint
results did not establish passage through the intervening vertical collision.
Readonly9m-radius map had338sampled surface nodes;755native queries and12lazy
blocked paths ended in unreachable_in_window even with96diagnostic iterations
allowed. This local improvement failure is not proof of no world route.
Private candidate-edge-controls/window-map artifacts are under
logs/recovery/grounding-20261029. No pawn position writes or autonomous outcome.

### DEV typed floor and sampled capsule controls (2026-10-29)

Current FindFloor yielded walkable support/nonpenetration; +100cm yielded no
support; -100cm yielded explicit initial penetration. Each query had one typed
callback; retained factory reuse kept native hooks14 with logical cleanup.
Player capsule34/88cm, profilePlayer and zero ignore arrays were observed.
The native full-capsule return Boolean distinguished current-clear from
below-floor-blocked, while copied Distance0 did not. A one-metre chord hit floor;
seven14.2857cm floor-following capsule sweeps were clear without pawn movement.
These are compatibility/sample controls, not autonomous or general traversal
proof. Private raw logs: R/logs/recovery/grounding-20261029. Full interpretation,
source searches and limitations are persisted in
docs/research/2026-10-29-player-grounding-native-controls.md.

### Controlled DEV routing reproduces friend failure; context switch is insufficient (2026-10-29)

With ClaudeDev stationary, the bounded diagnostic queried the actual recorded
start/goal. Nil and explicit Default returned the same six points and partial
endpoint `[71.68,1862.08,-35.2]`; Gigantic returned a different partial path.
Thus a mover-only explanation cannot account for that endpoint, and selecting
Gigantic is not a demonstrated cure. Tight projection of both endpoints of a
physically climbed short segment failed, including explicit Default. Expected
feet are within the +/-1.5 m centre-origin box, so merely lowering/widening the
box could select another floor rather than repair a coordinate conversion.

Indexed native PathPoints reads in nav_route_probe worked in these serialized
calls. UObject validity remains distinct from unknown native path validity.
A separate developer movement trace selected an old lower-floor trap exit,
stepped off the upper floor and failed landing, while HP100 was preserved.
This supports connector/floor validation; old n_ok counters are not present-day
clearance evidence. Source surveys and limits are in the 2026-10-29 research notes;
raw native and movement records stay private under logs/recovery/nav-dev-20261029.

### Nearby Lodestone construction/use and Fire Spirit controls (2026-10-28)

Developer-only on53fd3f7: normal21m movement and real build-menu placement
created node EDDE9FD844BE5F19890B94B8B4A96470, independently read from registry.
Native materials decreased32Stone/20Essence/1Core; Construction152->232. Its
real teleport to Temple travelled152m, consumed1Law and produced native success
sequence2->3. HP100, Gameplay and cleared ownership independently observed.
Existing-site placement failures do not establish unavailable construction.

Separate developer Fire Spirit control added native FireSpiritGameplayEffectInstance
and Player.Status.FireSpirit from an empty native effect list, with10FireRune
spent and the spell actor observed. This is direct effect evidence on the tested
body, not a formal spell-family score or an unaided Haiku result. Private evidence
is in R/logs/recovery/lodestone-20261028 and feedback-loop-20261028.

### Model-selected Lodestone travel verified on53fd3f7 (2026-10-28)

Haiku independently queried lodestones and selected teleport to the existing
developer-built base. Starting36m from Temple, the real tool approached/used
it and travelled129m; native Law1600 -> 1598, success sequence1 -> 2, destination
position, HP100 and empty Map13/29/Gameplay/strict ownership cleanup corroborate
the result. Four controller calls/no planner for the containing episode.
Construction was omitted, so only this subtask passed. Tested setup used public
root-stack transition duration0 configured before any map, a temporary headless
presentation measure; no autonomous construction or300m-chain claim.

### Haiku composes pickaxe production, equip and native mining (2026-10-28)

One stock-assisted diagnostic on5d2f662 produced a new Stone Pickaxe through
the real table, equipped BP_Pickaxe_Stone_C and broke a native stone node,
collecting13Stone. Independent Mining22 -> 35/level1 -> 2 and Artisan56 -> 76
corroborate production/work; all5provider calls used Haiku, no planner.
This is the third completed diagnostic task chain on the feedback repair,
not statistical generalisation or a milestone pass. A subsequent open level-up
request failed and remains in BUGS rather than being counted as another pass.

### Haiku recovers missing crafting station and completes production request

Recipe/stationfeedbackledtobuildingCraftingTable(4AshLogs,12ConstructionXP),
thenStoneLoggingAxe(8AshLogs+6Stone,20ArtisanXP), thena secondstandingtreefell
andnewwoodcollected. Nativeaxeaggregate1->2 independentlyverified. Existing
loggingaxeremainedheld(equipalready); do notclaimnewinstanceequipped. Two
harvestsadded10logs/+74WoodcuttingXP, reachinglvl9. No mid-episodeassistance;
startingStonewaspreviouslygranted, soresourceacquisitionfromscratchunproven.

### Haiku independently constructs a missing processing station (2026-10-28)

Aftercollecting2pondwater, stationreadreturnednone; Haiku chosebuildables,
builtCampfire andselecteditsactualnewID forcrafting2CleanWater. Nativebuild
cost6Stone, Construction+12XP (catalogestimate20),Cooking+2XP. No episode
operatorhints/grants/actions. SixStonecamefromcarriedassistedstock, so this
provesplanning/construction/usewithmaterials, notstoneacquisition. Health100,
strictidle/noclaims/Gameplay atterminal. ActualHaikuinputshowedunknownstation
coverageaftertravel andthefreshnewstation2.87m awayafterconstruction.

### Native water chain now settles its mover (2026-10-28)

Developer control on tested19302df: collect2 pond water, return to campfire,
process2CleanWater through realUI, CookingXP129->131,81.05s. Independent native
end: health100, bridge action/waiters empty, noarbiter owner/suspended work,
moveidle andGameplay input. This is current native cleanup evidence for the
ownership repair; autonomous water repeat is still pending. Feedback candidate
renders that actual terminal state in726 characters without new game reads.

### Native Lodestone construction and selection route (2026-10-28)

Receiving materials unlocked BUILDPIECE_Lodestone; actual real-menu build used
32 Stone/20 Rune Essence/1 Vault Core and gained80 Construction XP. Catalog
750XP estimate differs from native outcome. Registry added developer stone;
existing Temple destination and two Law Rune cost verified. The existing local
component TryTeleport(from.guid,to.guid), after real use opened the map, caused
a native success RPC sequence increase and independently observed arrival.
Do not confuse these developer controls with autonomous capability proof.

MapUIAPI.IsShowingMap can be false with actual Map13/TopBar29 and blocking map
input still present. The real MainMenuUIAPI.NavigateBack(current parent) can
close both; active root-stack identity and later screen/input observations
are required. Repeated normal0.4 activation showed stale stack/new API parent;
headless compatibility remains under test. No forced widget state/callbacks.

### Advertised inventory mode now survives the real dispatch path (2026-10-28)

Read-only control on the same dev body: baseline 9345dec normalized the
requested raw=true to {}, yielding compact worn fields. Repaired 9516fc3
sent raw=true unchanged and the native handler returned loadout/pages/personal
fields. Candidate and post-deployment controls agree; no model inference,
grant or restart. Raw R logs/recovery/manifest-raw-{baseline,live,deployed}-20261028.*.
Forwarding for craft/attack/gather is regression-covered, not yet native
gameplay proof; native null interpretation and legacy planner paths remain
separate. Full evidence gate is recorded in PROGRESS and recovery notes.

### Two-speed control is sound; decision contracts need repair (2026-10-28)

Independent Sol source/trace review confirms Haiku chose the water chain,
including replenishment and return to the station after a real failure.
It also establishes silent chosen-argument loss, stale continuation context,
incomplete lifecycle/UI/perk information and prompt clipping. No phrase map
was found in inspected paths; compatibility aliases, read/action suppression,
executor retries and native reflexes do exist and must be attributed honestly.

September 2026 PUBG Ally and Gander primary papers support refreshed
observations, carried unfinished intent and explicit action lifecycle;
they do not provide a drop-in Dragonwilds runtime or prove stock Haiku can
master the game. Reuse bridge, observer, broker, arbiter and per-world stores;
adapt their missing contracts before adding another planner/framework.
Sources, limitations and staged evidence are in
research/2026-10-28-sol-adversarial-architecture-audit.md.

### Model-selected water replenishment and failure recovery worked (2026-10-28)

Haiku made four Clean Water across two batches, directed a drink, collected
new pond water for reserve, and returned to the known campfire after processing
truthfully reported out of range. Native final reserve two, Cooking +4 XP,
health100. Initial ingredients/station were assisted and overall terminal
check failed on an orphan mover; this is meaningful gameplay evidence, not
a complete stable run. Details: r28-clean-water-chain-20261028.md.

### Frozen spell judge discriminates real cast from a claim (2026-10-28)

The new non-judge native control runner used the exact Windstep case and
judge_dev: real cast passed, claims-only failed/not_achieved. Both independently
started not achieved. No model calls or validity promotion. Fresh native
loaded spell dump lists the same 52 IDs as the old catalog, but its exporter's
hard-coded label is not actual-build provenance. Current client remains
26162923, catalog label 26161880. See r27-m1-controls-and-mobility-20261028.md.

### Windstep chosen and cast by Haiku with native confirmation (2026-10-28)

After developer validation on e9200ff, the ordinary request "Please use
Windstep." produced two Haiku calls and a cast without Director assistance.
The independent native probe changed from no tags/effects to
Player.Spell.WindStep and DominionStatusEffect; health stayed 100, session
ended idle, parent watchdog did not expire. 12.422 seconds / $0.0028.
Raw R/logs/recovery/no-axe-pilot-20261028-114914-c1fdfcc8.json; parent
haiku-windstep-windstep_0286482672. This proves a requested cast, not choosing
it to solve a ledge or a full spell-coverage milestone.

### Additional production and stock targets differ correctly live (2026-10-28)

Deployed e9200ff, actual Controller read: native owned axe count one remains
observed_have=1, allocated_from_inventory=0 for default additional_output,
with one craft, eight wood, six stone and Crafting Table dependencies.
Explicit inventory_target remains satisfied by the owned axe. This verifies
information semantics, not executed crafting. The subsequent Haiku repeat
did not call craft_plan and harvested with the existing axe instead.
Evidence: R/logs/recovery/quantity-native-controller-20261028.json and
no-axe-pilot-20261028-113152-27866e44.json. No materials/tools/stations granted.

### Native effects verified a current-code shield cast (2026-10-28)

Developer-selected Tempest Shield used 15 Air Runes and independently added
Player.Status.TempestShield and BP_TempestShieldGameplayEffectInstance_C to
the native probe. Both were absent before; health stayed 100 and the UI/body
returned idle. This demonstrates the real casting path, not autonomous spell
choice or full coverage. The same deployment also exposes all 24 axe recipe
candidates, including the observed unlocked stone recipe. Production intent
still requires a separate quantity-mode fix. Evidence:
docs/research/r26-postfix-and-shield-20261028.md.

### Grave perception and persistent memory supported a real chain (2026-10-28)

The current state exposed a verified own grave 5.31 m away, containing an axe
and eight logs. Haiku chose to recover it and subsequently harvested five new
logs, with native +20 Woodcutting XP and a tree-to-stump transition. Persistent
death records also survive client restart in `client_io/state/last_death.json`.
Recovering an existing tool is useful autonomy; it does not prove new crafting.

Four typed hand getters returned null wrapper addresses and false validity,
with explicit null and valid-pawn controls and the installed UE4SS commit
`83330635` source checked. No VM-read permissions or binary changes were needed.
See `docs/research/r26-unaided-tree-chain-20261028.md` for evidence and limits.

### Ownership checks recursively compile the mover (2026-10-28)

move_arbiter loads a fresh arbiter; owns_move runs housekeeping, whose mv()
loads the entire move module into that fresh instance. Actual-module offline
instrumentation measured520arbiter+520nestedmove loads per160samplingtraces.
The existing public set_move(actualM) dependency injection removed nestedloads
while preserving all route/world checks;4.208->0.463s CPU in one fake comparison.
Live cost/benefit remains unproven. Runtime getters also returned coherent
filled-slot/quantity counts and known-positive rune counts without slot-array
traversal; main10observedrows/8702quantity matched10filled/8702items.
See docs/research/r26-short-local-planner-20261028.md; hands remain unknown.

### Actual local planner supplies an upper-level candidate (2026-10-28)

The read-only real-LP control lp_observe_4457c972ea returned7points, including
a157.3cm planned jump under the measured164cm envelope, to within~0.539mXY
and0.0074mZ of the requested floor point. No tolerance was supplied; a future
0.5m request must still reject this endpoint. No pawn input or displacement,
HP100,741traces/3replans and completed cleanup. This establishes planner output,
not an executed jump or safe route. A prior slower observer timed out and is
unknown rather than no-path. See docs/research/r26-short-local-planner-20261028.md.

### Current crafting response and navigation-context contrast (2026-10-28)

On deployedb29d97b, native craft_plan exposes3acquisition options each for Stone
and AshLogs, lower-bound counts and unknown insufficiency; no unconditional
currency shopping list. This was a developer read,0modelcalls, not autonomy.

Current reflected parameter classes and actual native calls supported the
paired navdata comparison. Nil/Default returned identical partial paths;
Gigantic's complete result began~3.1m above and~3.1m sideways from actualstart.
That contrast rejects a naive mesh-switch fix. No pawn movement/HP change or
navigation writes; exact evidence and research are in
docs/research/r26-crafting-deployment-nav-context-20261028.md.

### Deployed model view and actual prerequisite response (2026-10-28)

On9cacd96, a fresh native inventory passed through actual Controller._read to
FakeLLM next-turn input measured12963->1724UTF8bytes while retaining original
raw/enriched state, read uncertainty, positive rows and matching ToolCallID.
No provider calls. A subsequent natural Haiku run used craft_plan but no
inventory call, so it does not show a behavioral effect from view compaction.

Actual craft_plan expanded basic ingredient catalog recipes into42currency
and merchant station/craft steps; gathering appeared only in nested hints.
The fresh developer census independently saw loose Stone/AshLogs and a table
~33m away. Their visibility does not prove reachability. A one-item loose
pickup control then failed path_blocked, with no observed acquisition and
HP100. Preserve these failed observations and native uncertainty; no complete
prerequisite chain or autonomous pass. See the r26 model-gap native report.

### Actual inventory context size and current read access (2026-10-28)

The natural retry's actual enriched inventory tool result was13,068UTF8bytes.
The reviewed copied model view is1,929bytes with the same ToolCall ID, positive
fields, uncertainty and exact166/8/20 gap counts; full diagnostic logs and
controller inventory remain unchanged. This is a replay measurement, not a
provider token or behavior measurement. Research/crafting schemas were present
but unused. See docs/research/r26-tree-retry-20261028.md.

Current client1416 independently denied an OpenProcess handle requesting only
VM_READ and QUERY_LIMITED_INFORMATION(error5), despite successful identity and
other process-control access. No memory read or privilege mutation followed.
Prior pinned UE4SS TArray source can AddZeroed on out-of-range index access;
do not call a speculative index probe read-only or infer current layout from
the older26161880 dump. Native absence proof remains unverified.

### Current-code route admission exercised natively (2026-10-28)

Deployed50111a7 completed v2 recovery with one helper job, preserving server
and Steam. A required sameXY+50mZ move matched a no_path response and failed
without observed displacement; a scoped100cm route threshold let the measured
2m corridor exercise actual required-route execution. It arrived within0.4m,
and exact1000cm restoration and terminal idle were independently verified.
The actual binding world wasdev, with no namespace migration. These are bounded
developer controls, not an unassisted task, default long-route proof or a native
input-call count. The server loads its own experiment COPY; publication must
verify that file's raw hash, not merely update R/mod/experiments. See
docs/research/r26-route-controls-20261028.md for detailed evidence and limits.

### Stationary route controls and process identity evidence (2026-10-28)

At `[63.153,1875.565,-35.446]` on deployed83f0ce3, the existing DEV oracle
returned no_path/zero points for sameXY+50mZ and a two-point2.02m route for a
nearby2m goal. Native before/after position and health were unchanged; this is
an observed navigation contrast, not movement or autonomous-task success. The
legacy false metadata can still conflate getter errors. See
docs/research/r26-route-controls-20261028.md for raw evidence and limitations.

Read-only PROCESS_QUERY_LIMITED_INFORMATION queries obtained exact Win32
creation FILETIMEs and full images for retained server7016 and legacy helper
wrapper144/worker10016. CIM's missing command line was not evidence of process
absence or insufficient permission for this narrower query. These identities
were recorded privately before any process replacement. No privilege or ACL
change was needed. The reviewed helper requires independently terminal legacy
writers, pinned server/bridge/file continuity and a correlated FIFO ping; lock
ownership or a new helper PID alone cannot establish server idleness.

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


### Native floor controls and scoped lifecycle measured (2026-10-28)

Eight native query calls completed on DEV10824 without moving the pawn: six
control queries across two batches and two separate source-reader leases.
Raised+100cm returned no floor; lower-20cm returned walkable/negativeFloorDist
without penetration; lower-100cm returned floor-block=false/hit-block=true/
penetrating=true. Typed flags, exact cleanup, unchangedHP100/position/nav SHA
and stable registration verified. These distinguish real field meanings and
close/reacquire compatibility, not full clearance, safe drops or prevention.
See docs/research/r26-floor-observations-20261028.md and private archive
R/logs/recovery/floor-controls-1348bed1. No production runtime change or API
model calls. Goal remains original/unmet; next natural tree-task diagnostic is
being prepared with both Haiku roles under one shared6-attempt cap, not a
scripted gather/craft plan. Incomplete inventory coverage cannot count as
verified no-axe recovery.


### Explicit lifecycle candidate: full gate GREEN, isolated (2026-10-28)

Reviewed floor_read logical leases passed56 actual-hub fake checks,5 design tests and full gate1158/1 skipped381.80s (`logs/recovery/cf-b8d23d4b/check-all.log`), source hashes unchanged throughout. It remains disabled/unpublished to R and has no production consumer or support classifier. Logical cleanup/reacquisition preserves the native registration ledger; legacy/foreign/pending/ambiguous state refuses. Reliable external lifecycle invalidation and native attribution limits still apply. Deployedc145862 separately passed actual developer walk/Jump/air/landing/cleanup withHP100 and unchangednavmemory. No original milestone completion claimed.


### Current-source native walk and jump (2026-10-28)

On deployedc145862, DEV client10824 executed actual move.go_to, stopped its exact owned movement, and acknowledged cleanup. Walk trialjumpbind_walk_01f1dca16b02 observed28.93cm motion before owned stop. Then ONE developer synthetic same-height150cm jump edge trialjumpbind_jump_01a6b7c544e8 submitted actual Jump, observed airborne movement mode and about179.18cm peak rise, landed and settled. All sampled HP100; endurance0 was recorded, not changed. Both operators TERMINAL, watchdogs stopped, cleanupacktrue, nav_memory.json SHA unchanged, final body/arbiter idle/slotFREE. Position `[58.41,1819.8690782694,-30.754965129417]`. This is a developer-driven flat input-path check, not autonomous compound play, obstacle clearance, spells, ledge prevention or a GOAL score.

Raw operators and queue records are archived at `R/logs/recovery/jump-binding-publication-f59c07e4/native-evidence/`. Only the named completed private registrations were archived and removed from tools/live_checks; logs/state/per-world memory retained. Local runout scan queued a bridge restart while idle; actual movement operator explicitly retained the healthy bridge. No command was in flight during restart, no extra brain/API calls.


### Fresh process runout after source publication (2026-10-28)

NewDEV client10824 on sourcec145862 rejoinedClaudeDev at `[58.41,1820.934,-30.755]` (network-quantized). Typed current-floor callback and rearward capsule samples100/150/200cm away were blocking/walkable/non-line/nonpenetrating with normalZ1 and floor distance about2.14844cm. Exact diagnostic subscriber cleanup succeeded. This is local geometry evidence, not general coverage or a support-guard pass. Raw `R/logs/recovery/r26_jump_runout_20261028-result-full.json`.


## 2026-10-28: repeated flat walking release and ownership evidence

On DEV client11752 and deployed source0a1590d, three12-input developer flat walking trials reached450cm/s. Horizontal drift after owned input release was7.5254347176,6.9538611515 and7.3935943663cm, with observed stable rest and HP100. Actual callback cadence was about33ms. Sparse capsule observations showed walkable nonpenetrating flat support locally; they do not establish a general sprint/drop/streaming stopping margin. R/logs/recovery/r26-flat-{a,b,c}-operator-result-20261028.json retains raw status and cleanup evidence. The calibration character was harness-positioned and supplied; none is autonomous task evidence.


Each entry: what it is, the parameters, what it does, how it was verified, the build ID, and the sources.
Server build: **26161880** (Steam app 4019830, installed 2026-10-25). Engine **UE 5.6** (from UE4SS.log). Game module: `Dominion` (classes under `/Script/Dominion.*`).

Research notes with full source lists: `docs/research/2026-10-25-ue4ss-chat-bridge.md`, `docs/research/2026-10-25-phase4-body.md`.

**Code layout (2026-10-25):** the experiment modules named below as `mod/scripts/<name>.lua` now live in `mod/experiments/<name>.lua`, and `debug_run` still finds them by name. Proven code was promoted:
- `puppet_safe` became `mod/body/removal.lua`.
- `chat_relay`, `chat_as`, `name_register` and `names_probe` became `mod/body/speech.lua` (`DW_SAY_MODE=relay`).

See `docs/ARCHITECTURE.md`.

## Environment

### Current-code UI proof and partial Controller pilot (2026-10-28)

Release528ae99 passed1126/1-skipped full gate, deployed with24 affected paths byte-verified and preserved memory. On client11752, developer Crafting Table and Campfire/Processing interactions each returned screen_opened for the actual target owner after1 IA_Interact; cleanup followed verification and restored Gameplay with no claim leak. This covers two UI families, not all interactions or autonomous composition.

Corrected Controller-only diagnostic10 Haiku/0 Sonnet actually executed model-queued work and collected3 berries. Observed reflex consumption contributed to HP1->39.5, sustenance0->14.4, hydration0->17.8. Water acquisition failed65.4m away and cap0 prevented planner repair; returned stuck, no rest improvement. No new pilot supplies/hints; earlier developer structures/fixtures make this an assisted world. The unpumped first pilot is excluded from capability conclusions. End total1.0021/10 UTC-day,209 priced/0 unpriced. Private survival-pumped-result-20261028-002619.json and brain-live-20261028-002618-8932.jsonl retain evidence; no complete/fresh survival or goal proof claimed.

### Daytime rest and spell-created shelter, developer-driven (2026-10-27)

On deployed cde20004, real Summon Shelter casts each spent10 Astral and10 Earth runes, placed a native shelter with BedComponent/RestingAreaComponent and reported a verified actor effect. These spells/runes were already present; their original fixture provenance is retained. A first bed was absent by the next interaction after intervening dehydration damage; damage-dispel is consistent with its catalog description, not an independently traced destruction cause.

Controlled retry used the existing dev harness to advance time forward to10h, provide nutrition and health, never write endurance. At approximately10.75h and11.1h the native component reported the same CurrentRestingAreaActor, IsRestingtrue, IsSleepingfalse and IsInTimeframeForSleepfalse. Endurance rose33->54 over20s while resting; later sampled93. Baseline before casting was0. This establishes observed daytime restoration under these conditions; it does not assert an exclusive mechanism or universal recovery rate. Ordinary same-bed interaction later returned got_up, native restingfalse and DIM_Gameplay. The entering interact nevertheless returned path_blocked after movement retries: preserve that false-negative observation as R24. Exact entry timing and getter side effects are not established.

Private evidence: dev-drive-rest-controlled-result-20261027.json, dev-drive-rest-control-20261027.json, queue runs233753/234150/234448/234724/234836/235156 and corresponding native logs. Nutrition setup across controls granted2 Bread,1 Dirty Water and3 Clean Water, with declared health100 setups and time advancement; reflexes consumed the supplied food/drink through their normal input path. Main consume attempts then correctly found no bread or reported missing hotbar/bag water; do not mislabel those attempts successful. These are assisted diagnostics, not an autonomous survival or spell-selection score. Existing per-world progress/memory is preserved.

### Developer-driven station, real craft and tree felling (2026-10-27, dev)

At clean deployed cde20004, root drove the existing client tools with the API brain stopped. Before: Stone Logging Axe locked, recipe count83,8 Ash Logs/6 Stone, WCXP206/Artisan16; table63.24m away. Normal interact approached and pressed use; afterward native recipe getter true, recipe count90, actor-interaction set5->6 including table class. This case combines approach and use and does not isolate their effects. Interact falsely returned verification_failed: logs show DIM_CraftingMenu opened then orphan cleaner closed it twice before verification. Preserve that failed verdict; native unlock is independent evidence, not a rewrite of the action result.

Next craft at that observed table succeeded in2.0s, native result_code0, spent8 logs/6 stone, gained1 Stone Logging Axe, Artisan XP16->36, returned Gameplay mode. Equip succeeded. Explicit chop then took9.1s,4 swings/3 hits, actual standing-tree target became Ash Stump at [55.26,1828.92,-31.26],1 log obtained, WCXP206->219. This establishes real body capabilities under developer control, not unaided Haiku composition or goal completion. One harness set_health100 was used before the approach/use case; no items, recipes, spells or skills were granted, and final health remained1. Existing runes/gear were retained. No new death observed.

Private evidence: C:/gameserver/logs/recovery/dev-drive-session-20261027.json (five queue check records), dev-drive-unlock-after-20261027.json, original native before snapshots, client activity/vitals/logs. Runs231352/231454/231618/231652/231742; summed check durations49.6s, reported readiness waits60s, first run start-to-last end276s, not a measured sustained utilization rate.0 game-model calls; UTC spend remained the prior observed0.9880. Board trial552d7ceb backed up and parked via BoardOps with an assisted-trial reason, preserving history/state and preventing its old XP predicate from later being mistaken for autonomous success. New unaided prerequisite-chain evidence is still required. User approved offline -> developer-driven -> unassisted Haiku validation; AGENTS records the sequence.

### Current client limits and memory diagnosis (2026-10-27)

Read-only queue20261027-230505 on cde20004 reports t.MaxFPS30 and Dominion user FrameRateLimit/GameFrameRateLimit/FrontendFrameRateLimit30; idle-when-background0, VSync0, smooth/fixed frame modes false. These are configured limits, not measured frame rate. Both local shipping processes report Windows base priority8. Their resident working sets differ from private allocation: server approximately0.46GiB resident versus1.2GiB private; do not interpret Task Manager residency as an explicit server resource cap. The client launcher uses NullRHI/no sound; existing hang research below documents the historical30FPS stability precaution. Sources: private flat-fps-live-handoff.txt and process snapshots; [Epic command-line reference](https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-engine-command-line-arguments-reference), [Microsoft working sets](https://learn.microsoft.com/en-us/windows/win32/memory/working-set), [Chromium process architecture](https://www.chromium.org/developers/design-documents/multi-process-architecture/). Searches: `Codex app multiple processes memory subagents`, `Chromium multi process architecture renderers GPU utility`, `Windows process working set private bytes shared pages task manager memory`, `Unreal Engine NullRHI headless game tick fps`. Reuse existing native probes and process inventory; no tuning or process-kill workaround implemented.

### Autonomous construction and still-locked axe recipe (2026-10-27, dev)

On cde20004, original plain task552d7ceb built its own Crafting Table, independently observed as BP_Crafting_StartingBench_C_2147464285 at [56.25,1827.26,-31.4], with4 Ash Logs spent and Construction XP36->48. There were no axe/bench/material grants; this bounded run had initial harness health100. Native axe recipe remained not_unlocked, Woodcutting XP206 unchanged, no craft/equip/felling proof. Subsequent read-only progress probes found HasPickedUpItem true for Ash Logs and Stone, IsRecipeUnlocked false for the target,83 persistent recipes without that target, and no bench class among5 recorded actor-interaction classes. This makes bench interaction a hypothesis to test through autonomous play, not proof of the exact unlock rule. Historical proximity-only guidance must not substitute for this fresh native state. Private evidence: progress-diagnostic-cde.txt, progress-native-cde2.json and tree-cde-live-operator.txt.

### Material acquisition does not establish the requested work (2026-10-27, dev)

No-axe task87658e1c at clean code HEAD0e00f54 was marked done by its model-chosen AshLogs+1 predicate after gather returned source=sticks, swings=hits=broken=0. Native before/after probes show wood4->5 but WoodcuttingXP206, Construction36 and Artisan16 unchanged; no axe or bench/craft action occurred. This is a false runtime goal completion, not a passing recovery or benchmark result. The same-item material fallback is useful for prerequisites, but must be described separately from operations and actual evidence. Existing broken counts can include child/pickup targets; their use as matching-root proof is not verified. Sources: private brain-live-20261027-203109-8512.jsonl and noaxe-before/after probes; research/design in docs/design/gather-operation-recovery.md.

### Directed consumption with shared ownership (2026-10-27, dev client)

At source checkpoint 62e7f81, live queue run 20261027-201444 collected two matching Dirty Water on its first attempt. The food check initially returned busy / consumable verification pending; its configured retry consumed Bread, observed sustenance 33 -> 63 and an inventory decrement, and left DIM_Gameplay. A subsequent independent read found no active transaction, bridge action or waiters, with fed/combat services running. Preserve the initial deferral. This verifies the directed native input and cleanup path; it does not establish long autonomous survival or perfect causal attribution. The check harness restored health before water collection, so the resulting health recovery is not a companion achievement.

### Bridge adoption preserves service loops (2026-10-27)

On the local dev client, deploying the current bridge at an idle boundary adopted all six healthy services once (running, starts=1, adopt_pending=false). Fed loop 4 and combat guard loop 163 stayed unchanged, as did global vitals policy and combat orders. This confirms the existing idempotent start contracts can rebind current callbacks without duplicating loops. Private evidence: logs/recovery/automatic-adoption-20261027.json; code checkpoint 7c6a2e2.

### Client vs server version check (2026-10-25 22:25 UTC)
- Steam build ids are per app, so they never match. The client (app 1374490) is on **26162923** and the dedicated server (app 4019830) on **26161880**. Both logs report `LogInit: Build: ++dominion+hotfix-CL-254097` and `Net CL: 254097`, so it is the same game version.
- **Compare `Net CL` from the client and server logs, not Steam build ids**, to tell whether a patch needs a server update. `update_server.ps1` reported 26161880 -> 26161880, with nothing to update.

### Dedicated server install (verified 2026-10-25, build 26161880)
- **Install:** `winget install Valve.SteamCMD --source winget`, then `steamcmd +force_install_dir C:\GameServers\Dragonwilds +login anonymous +app_update 4019830 validate +quit`.
  - SteamCMD exits with code 7 after its first self-update without installing; run it again. About 5 GB.
- **Binaries:** `RSDragonwildsServer.exe` (230 KB launcher) and `RSDragonwilds\Binaries\Win64\RSDragonwildsServer-Win64-Shipping.exe`, the real server. We run the shipping exe directly with the working directory set to Win64.
- **Prerequisite:** the VC++ 2015–2022 x64 runtime (`winget install Microsoft.VCRedist.2015+.x64`). Without it, the server hangs at about 6 MB with no log and no visible error. Verified by installing it, after which the server ran.
- **Config:** `RSDragonwilds\Saved\Config\WindowsServer\DedicatedServer.ini`, section `[/Script/Dominion.DedicatedServerSettings]`.
  - Keys: `OwnerId` (the in-game Player ID), `ServerName`, `DefaultWorldName`, `AdminPassword`, `WorldPassword`, `PlatformPolicy=Crossplay`, `ServerGuid` (generated on first start, logged as `Generated missing ServerGuid`).
  - Sources: [TroubleChute](https://hub.tcno.co/games/dragonwilds/dedicated_server/), [XGamingServer config reference](https://xgamingserver.com/docs/runescape-dragonwilds/config-reference.md).
- **World:** on first start the server created `RSDragonwilds\Saved\SaveGames\CompanionDev.sav` from `DefaultWorldName` (log: `NewGame() ... WorldName[CompanionDev] ... MapName[L_World]`). It autosaves about every 5 minutes.
- **Log:** `RSDragonwilds\Saved\Logs\RSDragonwilds.log`.
- **Ports (from the log, not the guides):**
  - UDP 7777 for the game (`IpNetDriver listening on port 7777`).
  - UDP **8888** for the BeaconNetDriver. Guides say 7778; the RSE-Server Docker image agrees with 8888.
  - Windows Firewall rules for both are open to everyone.
- **Online:** Redpoint EOS. The log shows `CREATE SESSION - Success`, `START SESSION - Success` and `Session privacy set to [3] ... AdvertiseSession[1]`. The world is listed and has a password.
- **Navigation:** the server loads `RecastNavMesh-Default` and `RecastNavMesh-Gigantic` for `L_World`. Both log `Navmesh bounds are too large! Limiting requested tiles count` and are capped at 1,048,576 tiles. Navmesh coverage near the player still has to be checked (Phase 4).
- **Modded vs vanilla:** the ini has no "moddable" key, and no source documents one. "Modded" on hosts like Shockbyte means a Windows build with UE4SS. On our own Windows server, installing UE4SS is what makes it moddable. Clients stay vanilla.

### UE4SS on the dedicated server (verified 2026-10-25)
- **Version:** UE4SS `experimental-latest` (`UE4SS_v3.0.1-1181-g83330635`, assets dated 2026-10-17). Stable v3.0.1 predates UE 5.4. It detects `Using engine version: 5.6`, and the PS scan succeeds in about 2.7 s. [Release](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest)
- **Loader:** UE4SS's own proxy fails on native Windows.
  - That proxy is generated from `System32\dwmapi.dll` ([UE4SS build docs](https://docs.ue4ss.com/dev/installation-guide.html)).
  - The server never loads `dwmapi.dll`.
  - Renamed to `version.dll` (as [RSE-Server](https://github.com/kevinw9092/RSE-Server) does under Wine), it doesn't export the `GetFileVersionInfoW`, `GetFileVersionInfoSizeW` and `VerQueryValueW` that the exe imports. Windows then raises an invisible loader error, and the server hangs: 6 MB, one thread in `LpcReply`, `UE4SS.dll` never loaded. Verified with pefile and with a control run without the DLL.
  - **Fix:** use [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader) x64 `version.dll` (v10.0.0), with `version.ini` set to `[GlobalSets] LoadFromScriptsOnly=1, LoadRecursively=0, LoadExtraPlugins=ue4ss\UE4SS.dll, DebugLog=1, ModernUI=0, DisableCrashDumps=1`.
  - UE4SS then loads from `Win64\ue4ss\`, and the ASI loader logs to `Win64\VERSION.log`.
  - Script: `tools/install_ue4ss.ps1`.
- **Headless settings:** the shipped `UE4SS-settings.ini` already has `ConsoleEnabled=0`, `GuiConsoleEnabled=0`, `GuiConsoleVisible=0` and `EnableHotReloadSystem=0`.
- **Lua mods load.** UE4SS's `Win64\ue4ss\UE4SS.log` shows `Starting Lua mod`. Our `DWCompanion` mod is enabled with an `enabled.txt` in its folder.
  - `os.getenv` sees variables set by `tools/start_server.ps1`, and `io.open` append works. Verified: `logs/mod/mod_*.jsonl` contained `mod_loaded`.
- **Hooks:** `RegisterHook("/Script/Engine.PlayerController:ClientRestart", ...)` registers at startup. It returns PreId and PostId; the first is 5.

## Bridge
- Decision: append-only JSONL files (protocol in `brain/BRIDGE_PROTOCOL.md`), with the Lua side in `mod/scripts/bridge.lua`. Rationale and alternatives (LuaSocket, C++ mod) are in the research note, section E.
  - Pure Lua and Python, so it ports to the native Linux UE4SS. LuaSocket stays a possible later upgrade behind the same `Transport` interface.
- Offline-verified: Lua 5.4.5 (`winget install DEVCOM.Lua`) runs the body against Python `BridgeClient` in `tests/test_lua_bridge.py`. The in-game `!ping` gate is still open.

## Chat
- Research says Dragonwilds has public text chat (256 characters, with a spam throttle). No class or function names are published and no mod reads it yet. Hook candidates come from the dump (below).

## Observed in the server log during Luis's first session (build 26161880, 2026-10-25)
- **Join sequence** (default log, no hooks needed):
  1. `LogNet: Login request: ?...Name=<epic name> userId: RedpointEOS:<id>`
  2. `Join succeeded: <name>`
  3. `Server_SetPlayerGuid_Implementation()`
  4. `SetPlayerCharacterInfo() ... Character Name[Zezima] Guid[DCG:<OwnerId>]`
  5. `LogDominionPlayerControllerBase: PlayerChar entered world`
  These lines are a reliable "player joined" signal that can be tailed from the log.
- **The character profile is client-owned.** Each client streams its character save to the server on join: `Remote Character load starting`, `Player profile stream completed ... Size[205758]`, `LoadStateFromJson`. Inventory and character persistence are tied to the client save. This matters for give and inventory skills.
- **Classes:** the player pawn is `BP_PlayerCharacter_C`. NPC example: `BP_NPC_Saradomin_Statue_C`.
- **Equipment:** `DominionPlayerEquipment` logs `HandleHeldBunchedRepd() : CurrentHoldable: <item id>` when the held item changes. Item IDs seen: `weap_mace_skullsplitter`, `tool_logging_axe_adamant`.
- **Woodcutting:** after a tree was cut, the log shows `DominionLog: DropItems() : No ItemDataClass specified; no items will be dropped`.
- **Actions are server-authoritative:** `DomNetActIntIds: AUTH : Action Validated ... Accepted : START : Evade`.
- **Chat:** typing `!ping hello` produced **no** line in the default server log. Chat must be hooked, using candidates from the dump.
- **Noise:** `LogNetPlayerMovement: Warning: ServerMove: TimeStamp expired` repeats constantly while a GFN player moves. Filter it when tailing.

## Phase 2 hooks: verified in game (build 26161880, 2026-10-25 12:23 UTC, Luis via GFN)
Hooks are registered 30 s after mod start, from `mod/scripts/hooks.lua`. Candidate analysis: `docs/research/2026-10-25-dump-chat-inventory.md`.

**Fired:**
- `/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage(FChatMessageData, FChatPlayerFilterData)`
  - Runs once per chat line. `self` is `BP_PlayerController_C_*.PlayerChat`.
  - Text: `params[1]:get().MessageBody:ToString()` gave `"!ping hello"`. Sender: `.SenderData.PlayerId` gave `256`.
  - **Text chat exists and the mod can read it.** The line is forwarded to the bridge as a `command_received` event. Verified in `bridge_io/body_to_brain.jsonl`.
- `/Script/JagexChatBackend.PlayerChatComponent:Server_SendPlayerEvent(FChatPlayerEventData)` fires on join.
- Item pickup (two `BP_Spawner_AshBranch_0x_C` sticks) fired, in order:
  1. `/Script/Dominion.PlayerInteractionManager:Server_RequestInteraction(InteractionComponent, Collider, bSecondary=false, bRelease=false)`. `self` is `BP_PlayerCharacter_C_*.BP_Components_InteractionManager`.
  2. The BP bound event `BP_BaseGatherableResource_C:BndEvt__..._OnInteraction__DelegateSignature(BP_PlayerCharacter_C)`.
  3. `/Script/Dominion.BaseInteractableResource:OnInteraction(BP_PlayerCharacter_C)`.
  4. `/Script/Dominion.PlayerInteractionManager:Multicast_AcknowledgeInteractionRequest(InteractionComponent, false, false)`.

**Did NOT fire** (called natively, so UE4SS hooks never see them):
- `DestructibleWorldActor:OnHealthChanged`. Two trees were each felled in one hit with an adamant axe.
- `BaseInteractableResource:DropItems`.
- `InventoryComponent:AddItem`, `AddItems` and `AddItemByData`.
- `DominionPlayerController:OnNewInventoryChangedLogEvent`.
- `PlayerController:ClientRestart`.

Inventory changes will have to be checked by reading inventory state (polling `GetInventory()`) instead of hooking. That fits CLAUDE.md principle 2 anyway.

## Debug trigger and hot reload (verified 2026-10-25)
- `debug_run {module, fn="run", args}` is a bridge command, implemented in `mod/scripts/debug_cmds.lua`.
  - It clears `package.loaded[module]`, requires the module again from disk, then calls `module[fn](log, args)` from the bridge poll, which runs on the game thread.
  - The workflow: `tools\deploy_mod.ps1` while the server is running, then `.venv\Scripts\python.exe -m tools.bridge_cmd debug_run "{\"module\":\"follower_test\",\"args\":{\"action\":\"status\"}}"`. **No server restart, so a connected player is not kicked.**
  - Verified with `body_probe` and `follower_test` on the live server. `main.lua`, `bridge.lua` and `hooks.lua` still need a restart to change.
- Idle world: `body_probe` found 1 game mode, `L_World`, 0 player controllers and **0 AI characters**. The AI director spawns creatures only around players, so Phase 4 experiments need Luis connected.
- **Phase 4 path:** the game has a native, server-side follower system.
  - `ADominionPlayerCharacter:GetFollowerComponent():ToggleFollower(UFollowerDataAsset*)`, with `DA_Kalphite_Friend` (the Pharaoh's Sceptre summon) as the data asset.
  - `ADominionAICharacter:Confuse(InConfuser, bShouldFollow)` makes an existing creature follow.
  - Details: `docs/research/2026-10-25-dump-body.md`. Experiment module: `mod/scripts/follower_test.lua`.

## ROUTE 1 WORKS: a server-driven player character (verified 2026-10-25, about 13:00 UTC, Luis via GFN)
Module `mod/scripts/puppet_test.lua`, run through `debug_run`.
1. `luis:GetWorld():SpawnActor(StaticFindObject("/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C"), {X,Y,Z}, {Pitch,Yaw,Roll})`, placed 3 m in front of Luis.
   - The server survived (1262 MB). **Luis saw a player character standing still.**
2. `puppet:SpawnDefaultController()` gave it a plain `/Script/AIModule.AIController`, with no PlayerController and no PlayerState.
3. `ai:MoveToLocation(luis_loc, 150, true, true, true, false, nil, true)` returned `2` (`EPathFollowingRequestResult::RequestSuccessful`).
   - **Luis confirmed it walked to him.**
- **Conclusion:** a `BP_PlayerCharacter_C` controlled by an AIController spawns, replicates, path-finds on the navmesh and animates on a vanilla client.
- **Next:** equipment and armour on the puppet, combat, loot, and how it looks (blank vs geared).

## BLOCKER (investigating): unpossessing an AI-controlled player character freezes the server (2026-10-25)
- **Symptom:** the game thread deadlocks. CPU use drops to 0, the log stops, and the bridge stops answering, right after `LogDominionPlayerCharacter: Character [BP_PlayerCharacter_C_*] unpossessed`.
- **Bisect results** (each run on a fresh server; `DW_NO_HOOKS=1` and `DW_NO_COMPANION=1` turn our hooks and companion loop off):
  - A: spawn, then destroy without possessing → **OK**.
  - B: spawn, possess (SpawnDefaultController → AIController), destroy, with hooks and companion off → **hangs**. So it is not our code.
  - C: possess, then `AIController:UnPossess()`, nothing destroyed → **hangs**.
  - D: possess, then destroy only the pawn (the controller is kept) → **hangs**.
  - E: possess via an AIController with `bWantsPlayerState=true` (the UE bot pattern), then destroy → **hangs**.
  - Both `K2_DestroyActor` and `SetLifeSpan` trigger it, because both unpossess.
- **Conclusion:** Dominion's unpossess path for `BP_PlayerCharacter_C` blocks when the controller is not a client-backed `DominionPlayerController`. Hypothesis: it waits on a client exchange such as the character-profile save stream.
- **Workaround:** keep one puppet alive for the server's lifetime and never unpossess it. Its death may trigger the same path; untested.
- **Next:**
  - Find the unpossess and death code paths in the dump (`ReceiveUnpossessed`, `OnUnPossess` and their overrides).
  - Optionally take a native stack dump of the frozen process, which needs Luis's OK (CLAUDE.md rule on native tooling).

## Route 1: puppet dressed and armed (verified 2026-10-25, about 13:15 UTC, Luis via GFN). Module: `mod/scripts/puppet_gear.lua`
- **Armour/cape:** write `puppet.PlayerEquipmentComponent.Current{Head,Body,Legs,Cape}Wearable = <UWearableEquipmentData>`, then call `OnRep_Current<Slot>Wearable(nil)` and `ForceNetUpdate()`.
  - **Luis saw the full Zamorak T6 set and the Attack skillcape on the puppet.**
  - Data assets: `/DowdunReach/Gameplay/Character/Player/Equipment/{Head,Body,Legs}/ITEM_Armour_T6_<Slot>_Zamorak...` and `/Game/Gameplay/Character/Player/Equipment/Cape/ITEM_Cape_Trimmed_Skillcape_Attack...`.
- **Appearance:** copy `PlayerCustomizationComponent.CustomizationSaveData.<Handle>.DataTable/RowName` field by field (Luis: `male_A_01`, `male_D_03`, `Preset15`, ...), then call `OnRep_PlayerCustomization()`. The calls returned OK. Luis did not separately confirm the face and hair; to check.
- **Held weapon:**
  1. Spawn the weapon's own held-actor class (`BP_Mace_Skullsplitter_C`) with `SpawnActor`.
  2. Set `w.HeldEquipmentData = ITEM_Mace_Skullsplitter`.
  3. `w:K2_AttachToComponent(puppet.Mesh, "prop_r", 2, 2, 1, false)`.
  4. Set `eq.HeldEquipmentActorRight = w`, call `eq:OnRep_HeldEquipmentActorRight(nil)`, then `ForceNetUpdate`.
  - **Luis saw the puppet holding the Skullsplitter.** `HeldEquipmentItem` is nil and the ID is 0; the item normally lives in the PlayerController's `BP_Components_Inventory`. It still renders.
- Luis's real held actor, for reference: class `BP_Mace_Skullsplitter_C`, socket `prop_r`, parent `CharacterMesh0`, ID 2.

## ROOT CAUSES of the "freezes" (crash-dump analysis, 2026-10-25). The freezes were crashes.
- **UE4SS's crash handler blocks.** `UE4SS CrashDumper.cpp` writes `ue4ss/crash_<ts>.dmp`, then calls `MessageBoxW("Crashdump written to ...")`. No setting, flag or debugger check skips it ([source](https://raw.githubusercontent.com/UE4SS-RE/RE-UE4SS/main/UE4SS/src/CrashDumper.cpp)).
  - On a headless server nobody clicks OK, so every crash looks like a deadlock: 0% CPU, the log stops, the bridge is dead, players can't connect.
  - Seen live with `cdb -pv`: thread 0 sits in `USER32!MessageBoxW` called from `UE4SS!UE4SSProgram` inside `UnhandledExceptionFilter`.
  - **Mitigation:** `tools/watchdog.ps1`, started with `tools/start_watchdog.ps1`. When a new dump appears it kills and restarts the server, and it restarts a missing process. `stop_server.ps1 -Hold` stops without an auto-restart.
- **Unpossess crash** (bisect runs B–E; dumps `crash_2026_10_25_13_5x/14_0x`):
  - Access violation in game code reading `0x1248`, which is null plus the offset of `ADominionPlayerController::LoadoutComponent` (CXXHeaderDump `Dominion.hpp:10214`, `// 0x1248`).
  - The call chain goes from our Lua `UnPossess()` / destroy into game code. Dominion's unpossess path reads `PC->LoadoutComponent` without a null check, and for an AIController that PC is null.
  - Any unpossess of an AI-possessed `BP_PlayerCharacter_C` crashes: destroy, SetLifeSpan or UnPossess, with or without bWantsPlayerState.
- **Damage-call crash** (`crash_2026_10_25_14_07_41`):
  - Access violation inside `UE4SS!LuaType::push_structproperty`, then `push_uint32property`, reading `0xffffffffffffffff`.
  - It happened while UE4SS converted our Lua table into the `TArray<FTypeDamage>` argument of `UDamageComponent:PredictDamage`. The cause is struct or array marshalling (a bad table shape, or a UE4SS bug). **`pcall` cannot catch native access violations.**
- **Debug toolkit:**
  - WinDbg `cdb.exe` (`winget install Microsoft.WinDbg`) is at `C:\Program Files\WindowsApps\Microsoft.WinDbg_*\amd64\cdb.exe`.
  - Live hang: `cdb -pv -p <pid> -c "~*kn; q"`.
  - Dump: `cdb -z <dmp> -c ".ecxr; .exr -1; kn 25; q"`.
  - Offsets: grep `// 0x<offset>` in `dumps/<build>/CXXHeaderDump`. The game ships without symbols, so we see module and offset only, and frames as `src_strerror+N` (meaningless names).
- **Combat (E3), seen by Luis:**
  - The puppet walked to a Kebbit (`MoveToActor`), and `BP_PerformAttack(BP_Player_Sword_Attack1_C, {Data=PA_Attack_Sword CDO, PlayerOwner=puppet, EquipmentHand=1, ActionInputType=0, DesiredActionTarget=kebbit})` **swung and did damage**.
  - The Kebbit fought back, treating the puppet as a player: `TryPerformAttack ... against player BP_PlayerCharacter_C`.
  - `HealthComponent:SetIsImmortal(true, puppet)` kept the puppet alive.

## Unpossess crash: fix bisect (build 26161880)
Run 2026-10-25, 14:17 to 14:40 local, with nobody connected. The spawn point was `{X=11597,Y=185837,Z=-3000}`. Each step went through `debug_run puppet_test` / `puppet_safe`. A crash was detected by counting new `ue4ss/crash_*.dmp` files.

**FIX (verified): destroy the pawn's `PlayerRangedAttackComponent` before any unpossess.** After that, `UnPossess`, `SetLifeSpan` and destroy all work. The reusable version is `M.safe_remove(puppet)` in `mod/scripts/puppet_safe.lua`.

**Root cause, from disassembly of the crashing function (image offset `+0x5AC3E60`, crash at `src_strerror+0x36712cb`):**
- The handler is `UPlayerRangedAttackComponent::OnPlayerControllerChanged(Pawn, OldController, NewController)`.
- It is called through the pawn's controller-changed delegate (frames 01-03: exec thunk, then ProcessEvent).
- It casts `OldController` to `ADominionPlayerController`. It then checks `IsValid(OldController)` (the uncast pointer, via `RF_MirroredGarbage` `0x40000000` at `[obj+8]`), and reads `Cast->LoadoutComponent` (`+0x1248`) from the cast result. That result is null for an AIController.
- How the handler was identified: the `this` register (`rdi=0x1e6616423b0`) in dump `crash_2026_10_25_14_22_23` matched the logged address of `BP_Components_PlayerRangedAttack`. The `addrs` action logs the address of every component before unpossess.
- All 8 unpossess dumps (13:52 to 14:22) crash at the same instruction. The 14:07 dump is the separate UE4SS marshalling crash.

| # | Experiment | Crash? | Dump / offset |
|---|---|---|---|
| 0 | (earlier) strip `PlayerActionPerformerComponent` with `comp:K2_DestroyComponent(comp)`, then unpossess | yes | 14_16_25, read `0x1248`, same rip. **Invalid test:** `K2_DestroyComponent(Object)` only destroys when `Object` is the owner, so it was a no-op. |
| 1 | strip all 5 (PlayerActionPerformer, PlayerEquipment, PlayerRangedAttack, PlayerMeleeAttack, Sprint) with `K2_DestroyComponent(pawn)`, then `UnPossess` | **no** | log shows "unpossessed"; same PID |
| 1b | after 1, destroy the unpossessed pawn | no | — |
| 2a | strip PlayerActionPerformer only (fixed call), then unpossess | yes | 14_22_23, read `0x1248`, same rip. `this` = BP_Components_PlayerRangedAttack. (A destroyed zombie puppet was also possessed in this run; see the note below.) |
| 2b | strip **PlayerRangedAttackComponent only**, then `UnPossess`, then destroy the pawn | **no** | — |
| 2c | `puppet_safe` (strip ranged, `UnPossess`, `SetLifeSpan` on pawn and controller) | no | — |
| 2d | `puppet_safe {unpossess=false}` (strip ranged, then `SetLifeSpan` only, so the destroy itself unpossesses) | no | — |
| 2e | armed puppet (`puppet_gear arm sword`), then `puppet_safe` (also removes the held weapon actor) | no | — |
| 2f | 3 back-to-back spawn → possess → `safe_remove` cycles | no | — |
| 2g | forced GC (`KismetSystemLibrary:CollectGarbage`, `puppet_test gc`) after 6 removals | no | all 6 garbage pawns and controllers purged |
| 3 | clear the pawn's `ReceiveControllerChangedDelegate` | not run | It is a sparse delegate (`FPawnReceiveControllerChangedDelegate`, `Engine.hpp:10642`, size `0x1`, stored in global sparse storage). UE4SS 3.0.1 has no Lua API to clear it. Not needed. |
| 4 | possess with a `BP_PlayerController_C` | not run | The fix made it unnecessary. The disassembly suggests it would pass the cast, but AI MoveTo would be lost. |
| 5 | parking fallback | not needed | — |

**Notes:**
- **Zombie actors.** After `SetLifeSpan`/destroy, a puppet stays in `FindAllOf` until GC runs (minutes on this server), at location 0,0,0. On it, UE4SS `IsValid()`, `IsActorBeingDestroyed()` and `KismetSystemLibrary:IsValid()` do not report it as dead. Only `HasAnyInternalFlags(0x200000)` (Garbage) is true. `puppet_test`, `puppet_gear` and `puppet_safe` now skip objects with `Garbage|Unreachable` (`0x10200000`). Before this, a "possess all puppets" step would possess the zombie too.
- Unpossessing without destroying the controller leaves an orphan AIController. `puppet_safe {orphans=true}` destroys plain AIControllers that have no pawn.
- **Untested:** the puppet's death or respawn path. It probably fires the same controller-changed handlers, so test it before letting a puppet die. The fix (strip ranged first) only applies at removal time. A puppet with the ranged component stripped probably cannot use ranged attacks.

## Client freeze from injected chat RPCs (2026-10-25, about 13:36–13:38 UTC). LESSON: client RPCs are dangerous
- `say` called `PlayerChat:Client_ReceiveChatMessage(FChatMessageData{SenderData={CharacterGuid, PlayerId, Color}, MessageBody})` with no `PrimaryNetId`/`SecondaryNetId`. Variant A added Luis's own GUID and PlayerId; variant B was `pc:Client_DisplayTextNotification({TagName=None}, FText)`.
  - The server-side calls returned OK, and **nothing displayed** on Luis's client.
  - Then **Luis's client froze**: NPCs stopped moving and the inventory would not open. The client closed the connection (`ControlChannelClose`, 13:38:25).
  - **The server stayed healthy.** Most likely cause: a malformed reliable client RPC broke the client's chat/UI or its channel.
- **Rules from now on:**
  1. No hand-built structs in Client_* RPCs to a live player. Speech defaults to `DW_SAY_MODE=log` (`start_server.ps1`).
  2. Untested native calls run offline (no players) first. Client-affecting calls can't be canaried without a client, so those need Luis's explicit go-ahead and a warning.
- **Hang detection added:** the mod writes `logs/state/heartbeat.txt` from the game thread every 10 s. `watchdog.ps1` restarts the server after 60 s stale (3 min grace after start), capturing `cdb` stacks to `logs/hang_*.txt` first.
- Puppet warning seen: `ADominionPlayerCharacter::OnWorldLoadedAroundCharacter - DominionPlayerState must be valid`. The puppet has no PlayerState, and the overhead name shows "Character Name Here" (Luis would like it to say "Claude").

## SPEECH WORKS AS "Claude" (verified 2026-10-25, 13:44 UTC, Luis via GFN)
1. **Route:** re-send a **genuine** client-built `FChatMessageData` through the server's own `PlayerChatComponent:Server_SendChatMessage`, from a post-hook on Luis's real message (`mod/scripts/chat_relay.lua` for the `!echo` test, `mod/scripts/chat_as.lua` for `!as`). Change only `MessageBody`, plus `SenderData.CharacterGuid` set to the bot's GUID.
   - `!echo hello` displayed `[Claude] hello` under Luis's name.
   - Hand-built structs with empty NetIds were dropped, and are suspected of freezing the client (see "Client freeze").
2. **Name:** the client resolves the sender name from `GameState.DisplayNameComponent.SanitizedCharacterNames`, keyed by **account string plus CharacterGuid**. Read-only probe: `mod/scripts/names_probe.lua`.
   - An entry registered with an empty account (`","`) displayed "Unknown Character".
   - **Fix:** `mod/scripts/name_register.lua` temporarily sets `Luis.PlayerState.OwnerGuid.CharacterGuid` to the bot GUID, calls `DisplayNameComponent:Server_RegisterCharacter(ps.OwnerGuid, "Claude")`, and restores the GUID in the same tick. Restore verified.
   - **Luis saw the line as "Claude".**
3. **Remaining for spontaneous speech** (the bot speaking without Luis's message as the template): still needs a way to send a well-formed message outside the hook. Options:
   - Cache a template at hook time, if UE4SS can copy the struct.
   - Find a server-side sender helper.
   - Have replies piggy-back on the triggering chat line.
   - Also: the puppet's overhead name ("Character Name Here") likely needs the same registry entry plus the puppet's character GUID set.
- **Performance check during "lag":** `FindAllOf` takes about 1 ms (15 AI, 1 pawn); VM CPU 5%; server about 15% of one core; 2.5 GB RAM free.
  - The lag is likely network jitter between GFN and the VPS (persistent `ServerMove: TimeStamp expired` on Luis's connection).
  - Possibly Defender scanning the hot files (`MsMpEng` high CPU time). Defender exclusions are pending Luis's OK.

## Performance telemetry (build 26161880, 2026-10-25). Is lag the server or the network?
**Three sources, joined by `tools/perf_report.py`:**
1. **Game-thread frame times:** `mod/scripts/perf_sampler.lua` writes to `logs/perf/mod_perf.jsonl`, one line per 10 s.
   - Arm it with `debug_run {"module":"perf_sampler"}`. It runs once per server run; arming again returns `already=true`. `args.action` can be `status` or `stop`.
   - `main.lua` auto-arms it 60 s after start. `DW_PERF=0` disables that.
2. **Host counters:** `tools/perf_counters.ps1 start|stop|status|recreate` creates the logman collector set `DWPerf`. It writes CSV every 10 s to `logs/perf/host_counters_<mmddhhmm>.csv`, with a new file per start and every 24 h.
   - It covers CPU (total and per core), queue length, available MB, pages/sec, disk % and latency, NIC bytes, UDPv4 datagrams and receive errors, the server process (CPU, working set, IO), MsMpEng, and python*.
   - It runs as SYSTEM and does **not** auto-start after a reboot. The CSV timestamps are local time; the header carries the UTC bias.
3. **Server log:** the report scans `RSDragonwilds.log` and its backups for:
   - `ServerMove: TimeStamp expired` lines, hitch lines, saturation and `ClientAdjust` lines.
   - `UNetConnection::Close` with its `Result=` (`ControlChannelClose` means the client closed the connection itself).
   - Autosaves (`SaveGameInternal() : Starting save` up to `Save completed`), and a **tick rate derived from the log's own frame counter** (`[hh.mm.ss:ms][frame%1000]`). That last one works on old logs, before the sampler existed.

**Run the report:** `.venv\Scripts\python.exe -m tools.perf_report` covers the last 60 min. `--minutes N`, `--since/--until` (UTC) and `--no-timeline` change that.
- It prints a per-minute timeline and a verdict, with the thresholds printed beside it.
- **Tick:** avg >= 27 Hz, <= 0.5% of frames > 50 ms, and <= 0.2 unexplained >100 ms hitches/min.
- **Host:** CPU > 80%, busiest core > 95%, RAM < 500 MB free, pages/sec > 1000, or disk > 20 ms. Any of these in >= 5% of samples counts as saturated.
- **Defender:** > 50% of a core, checked against slow-frame windows within ±15 s.
- **Network:** ping spikes (> 150 ms, or max minus p50 > 50 ms), TimeStamp expired, connection timeouts, and host UDP receive errors.
- **Hitch causes:** each > 100 ms hitch is matched to an autosave, or to a bridge command or `debug_run` (from `bridge_io/brain_to_body.jsonl` and the mod log) within -1..+5 s.

**Verified facts:**
- **Clock:** `Default__GameplayStatics:GetRealTimeSeconds(World)` costs about **5 µs** per call (200 calls timed with `os.clock`, about 1 ms resolution).
  - It returns `UWorld::RealTimeSeconds` as a double, so consecutive reads give exactly one world tick.
  - `World` comes from `FindFirstOf("GameModeBase"):GetWorld()`.
- **Frame loop:** `LoopInGameThreadAfterFrames(1, fn)` fires once per engine frame.
  - `EngineTickAvailable=true`, and `DefaultExecuteInGameThreadMethod = EngineTick`.
  - Checked against `KismetSystemLibrary:GetFrameCount()`: 15,240 frames sampled against 15,241 engine frames, with 0 duplicates.
  - Cost: one UFunction call plus a few Lua ops per frame. The 10-s flush (sort, `FindAllOf` for PlayerController and DominionAICharacter, ping reads) takes <= 10 ms.
- **Ping:** `PlayerState:GetPingInMilliseconds()` works server-side and matches `CompressedPing*4`.
- **Tick rate:** the server ticks at **30 Hz** (frame time 33.3 ms). The log-frame-counter estimate gives the same figure (29.6–30.0 Hz).

**Baseline: 2026-10-25, 13:53–14:00 UTC, 7.3 min, Luis connected from GFN until 13:58, 15–19 AI.**
- **Tick:** 29.8 Hz on average; p50 33.3 ms, worst p95 34.2 ms, worst p99 39 ms. 0.09% of frames were > 50 ms.
  - There were 9 hitches > 100 ms:
    - 5 were **our own `debug_run catalog` experiments**, at 126 to **611 ms**.
    - 3 were **autosaves**, at 116 to 202 ms. The save takes about 0.38 s and recurs every 5 min.
    - 1 was unexplained: 196 ms at 13:56:59. It might be UE garbage collection; this needs a longer run.
- **Host:** CPU averaged 27% and peaked at 58%; the busiest core peaked at 64%. Free RAM never fell below 2,218 MB, and disk latency peaked at 0.6 ms.
  - The server process used 15% of a core on average (24% at peak), with a working set of about 1.3 GB.
  - **Not saturated.**
- **Defender:** MsMpEng averaged 20% of a core and peaked at 84%, with about 10 MB/s of IO. Of the 6 slow-frame windows, **0** coincided with a Defender spike.
- **Network:** Luis's ping was p50 45 ms, p95 57 ms, max 60 ms. There were 0 TimeStamp expired lines, 0 UDP receive errors and 0 timeouts. His one close at 13:58:01 was `ControlChannelClose`, which he initiated.
  - Earlier (log-only, 13:07 UTC): one burst of 46 `TimeStamp expired` lines on one character within about 1.5 s. That is a client-to-server packet gap, while the log tick held at 29.6 Hz.
- **Verdict:** server-side OK, so a VM upgrade is not indicated.
  - The spikes players can feel from the server are (a) our live `debug_run` experiments (up to 0.6 s) and (b) the 5-minute autosave (about 0.2 s).
  - Any other lag Luis sees would be on the GFN-to-VM path. Next time he notices it, note the time and run the report over that window.

## Nameplate / identity (build 26161880)
Investigated 2026-10-25, about 13:50–14:10 UTC, with nobody connected (the world was paused: `LogDomGameMode: Requested pausing as we have no player connected`). The client-side result is **UNVERIFIED** until Luis looks.

**How the nameplate gets its text (from the dump):**
- `BP_PlayerCharacter_C.BP_Player_Nameplate` (`UBP_Player_Nameplate_C : UPlayerNameplateComponent : UDominionWidgetComponent`), the widget `WBP_Player_Nameplate_C : UPlayerNameplateWidget` and its `PlayerNameTextBlock` are all native. Neither Blueprint adds any logic or properties.
- No name property or setter exists on the pawn. The name must come from the pawn's **PlayerState**:
  - `ADominionPlayerState.OwnerGuid` (`FDomOwnerGuid` = `CharacterGuid.InnerGuid` + `FDomOnlineCapableAccountGuid`, replicated with `OnRep_OwnerGuidUpdated`);
  - resolved through `GameState.DisplayNameComponent.GetCharacterDisplayName(OwnerGuid, ExistingCharacterName)` against `SanitizedCharacterNames` (key: `AccountGuidSaveStr` + CharacterGuid);
  - and/or `APlayerState.PlayerNamePrivate` (`OnRep_PlayerName`).
- "Character Name Here" is the widget's default text. A puppet with no PlayerState never gets a name, which matches the server warning `ADominionPlayerCharacter::OnWorldLoadedAroundCharacter - DominionPlayerState must be valid`.
- The exact client path (which OnRep refreshes the plate) is native and was not disassembled.
- Probe results:
  - `GameMode.PlayerStateClass` = `/Script/Dominion.DominionPlayerState`; `DefaultPlayerName` = "".
  - The account string the server derives from Luis's AccountGuid is `RedpointEOS:000286bf...,STEAM:7656...` (NetIdPrimary,NetIdSecondary). An empty AccountGuid gives `","`.

**Why not the stock bot route:**
- `AController::InitPlayerState` is not reflected.
- `AAIController` only creates a PlayerState in `PostInitializeComponents` when `bWantsPlayerState` is already true. UE4SS `SpawnActor` is not deferred, so setting the flag after spawn is too late. puppet_test's `player_state=true` and bisect run E therefore probably never had a PlayerState.
- Re-possessing with a new controller unpossesses the old one, which is the crash path unless `PlayerRangedAttackComponent` is stripped.
- Not used (an alternative if the manual wiring misbehaves): set `Default__AIController.bWantsPlayerState=true`, spawn the controller, restore the CDO, then `safe_remove` the old puppet and respawn.

**What works server-side (verified, no crash; `mod/scripts/identity_attach.lua {action=attach}`, then `body/identity.lua`):**
1. `SpawnActor(/Script/Dominion.DominionPlayerState)` at the puppet.
2. `ps:SetOwner(aiController)` and `ps.bIsABot = true`.
3. Write the bot GUID into `ps.OwnerGuid.CharacterGuid.InnerGuid` with scalar A/B/C/D writes. AccountGuid is left empty.
4. Raw pointer writes: `ai.PlayerState = ps`, `puppet.PlayerState = ps` (replicated pawn property), `ps.PawnPrivate = puppet`.
5. `DominionGameMode:ChangeName(ai, "Claude", false)`, giving `ps:GetPlayerName()` = "Claude".
6. `ForceNetUpdate` on both.
- **Result:** `GameState.PlayerArray` = 1 (the bot PS); the puppet and controller report the same PS, with `PlayerId` 0 and `PlayerColor.PlayerId` -1. No crash dump, and the heartbeat kept ticking.
- **Registry:** `DisplayNameComponent:Server_RegisterCharacter(<the puppet PS's own OwnerGuid>, "Claude")` added the sanitized entry `"," | 0C0FFEE1-00C0DE00-0BADF00D-00000001 | Claude`. That is exactly the key a client builds from this PS. No hand-built struct is involved.
  - It **appends a duplicate** to SanitizedCharacterNames every time it is called, so `body/identity.lua` checks first.
  - Whether the registry survives a server restart is unknown; identity re-registers once per run.

**Shipped:**
- `mod/body/identity.lua` (`ensure(log, puppet, controller)`, idempotent).
- `body/puppet.lua` calls it right after possession and immortality, and from `ensure_spawned()` for an adopted puppet without a PS.
- `DW_PUPPET_IDENTITY=0` disables it.
- Debug: `identity_probe` (read-only, includes the registry dump); `identity_attach {action=status|attach|register|detach|module}`.

**Open / to verify (Luis):**
- The overhead name reads "Claude" after (re)joining.
- Clients are not affected by an extra bot PlayerState in `PlayerArray` (player list, chat).
- World save with a PC-less PlayerState: the first autosave with Luis connected.
- Removal with a PS attached: `UnPossess` clears the pawn's PS; destroying the controller destroys its PS (engine `CleanupPlayerState`); untested here.

## Item catalog run and melee combo timing (build 26161880, 2026-10-25, live server with Luis connected; no crash, no restart)
- **Catalog run** (`mod/scripts/catalog.lua` through `debug_run`, staged, with a ping and a crash-dump count after each step; 9 old dumps before and after):
  1. Property reads only (`registry=false, attacks=false, soft=false`): 466 items, 342 ms of game-thread CPU.
  2. `attacks=true`: 117 actions and 119 attack-data classes, 350 ms.
  3. Registry (`GetAssetsByClass`): 466 assets. **Every held and wearable item is already loaded at idle**, so `LoadAsset` is not needed for this build.
  4. Soft refs (`HeldEquipmentActorClass`) read fine, e.g. `BP_Mace_Skullsplitter_C`.
  - Output: `data/items_26161880.json`, with 466 items (232 held, 234 wearable), 0 missing and 0 errors. Command: `tools.build_catalog --no-load --notifies`.
- **Attack timing is readable as properties.**
  - `UPlayerAttackData.RootMotionAttackData.Montage` (`InPlaceAttackData.Montage` is null for the Club) gives `SequenceLength`, `RateScale` and `Notifies` (`TArray<FAnimNotifyEvent>`: `NotifyStateClass`/`Notify`, `LinkValue` = start in seconds, `Duration`). The struct-array reads via `ForEach` did not crash.
  - Per swing, the montage carries:
    - `AnimNotifyState_AttackInputWindow_C`: the combo input window.
    - `AnimNotify_AttackDamagePoint_C`.
    - `AnimNotify_AttackResetChain_C`: the chain resets here if there is no new input.
    - `AnimNotify_AllowMovementInput_C`.
    - Evade/Secondary input windows, `InputCancelWindow_*`, `HyperArmour_C`, `Invulnerability_C` (visceral).
  - Club Attack1, for example: window 0.367–0.805 s, damage at 0.501 s, reset at 1.702 s, montage 2.567 s.
- **Skullsplitter** (`ITEM_Mace_Skullsplitter`, Club set, not Sword):
  - Primary is `PA_Attack_Club_C`, a melee "Attack": `BP_Player_Club_Attack1 → 2 → 3 → 4 → 5`, damage 13.5/13.5/15/18/24, stamina 17 each.
    - Attack3 → Attack4 needs `PerkV2_Attack_MeleeExtendCombo`. Without it, Attack3 → `Attack4_ShortComboEnd`.
    - Attack5 → Attack1.
  - Special: `PA_Attack_Club_Special_C`, "Block Breaker": `BP_Player_Club_SpecialAction_C`, damage 20, `SpecialChargeCost` 33.
  - Also: sprint `PA_Attack_Club_Sprint` (SprintAttack → Attack2...), visceral `PA_Attack_Club_Visceral`, block `PA_Block_Club`, jump `PA_Spell_Club_JumpAttack` (a magic-kind action named "Dig").
- **Sword** (`ITEM_Sword_Mithril`, `PA_Attack_Sword_C`):
  - `BP_Player_Sword_Attack1 → 5`, damage 11/11/13/15/20. Attack2 → Attack3 needs the perk; without it, Attack2 → `Attack3_ShortComboEnd`.
  - Special: "Barge", `BP_Player_Sword_SpecialAction_C`, damage 24, cost 25.
- **Puppet special charge:** `puppet.SpecialChargeComponent:GetSpecialCharge()` / `GetMaxSpecialCharge()` (no-arg getters) returned 100 / 100 on the live puppet.
- **Live resolve check** (`debug_run catalog fn=check_attack_data`): all 26 melee attack sets and 71 steps in the generated `mod/body/attack_data.lua` resolve with `StaticFindObject`, including the CDO path `<pkg>.Default__PA_*_C`. The puppet was holding the Skullsplitter, which maps to the Club set.
- **UNVERIFIED (needs Luis):**
  - Whether `BP_PerformAttack` with combo steps 2–5 and with the special plays and damages like step 1 did.
  - Whether issuing step k+1 at step k's input-window end chains visibly.
  - Whether the server enforces the extend-combo perk, stamina or special charge on these direct calls.

### Nameplate attempt 1: NEGATIVE (Luis via GFN, after a full restart)
- Setup: `body/puppet.lua` ran `identity.ensure` at spawn. The log showed `puppet_identity linked=true ps=DominionPlayerState_... name=Claude registered=true`, so the client created the pawn with the PlayerState already linked.
- **Result:** the nameplate **still read "Character Name Here"**.
- **Conclusion:** none of these is enough to fill the nameplate:
  - a linked `DominionPlayerState`
  - `PlayerNamePrivate` / `GetPlayerName()` = "Claude" (via `GameMode:ChangeName`)
  - `OwnerGuid.CharacterGuid` = bot GUID, with matching registry entries (`","` + bot GUID, and Luis's account + bot GUID)
- The pawn and its components carry no name or GUID properties. In the dump, only `ADominionPlayerState` holds identity (`OwnerGuid`, `PlayerColor`, `PlatformData`). The character info set by `SetPlayerCharacterInfo()` (`FPlayerCharacterInfo`, unreflected beyond `DisplaySlotName`) lives on the PlayerController, which is never replicated to other clients, so it cannot be the nameplate's source.
- Luis's PlayerState vs the bot's, side by side:

| Field | Luis | Bot |
|---|---|---|
| PlayerId | 256 | 0 |
| PlatformData.DisplayName | "luisdeburnaybastos" | "" |
| PlatformName | "WIN" | "" |
| PlatformType | 2 | 0 |
| PlayerColor | {R .658, G .168, B .063}, "D47247FF", PlayerId 256 | defaults, PlayerId -1 |
| UniqueId (FUniqueNetIdRepl) | valid | empty (not writable from Lua) |
| AccountGuid | RedpointEOS + STEAM | empty |

### Nameplate attempt 2 (applied live 2026-10-25, Luis connected; `mod/scripts/identity_platform.lua {action=apply, player_id=999}`)
- Wrote `PlatformData.DisplayName="Claude"`, `PlatformName="WIN"`, `PlatformType=2`, `PlayerColor.Color` (Claude orange) / `HexString="D97757FF"` / `PlayerId=999`, and `PlayerId=999`, then ForceNetUpdate.
- All writes read back, and no crash. FString property writes from a Lua string work in this UE4SS.
- The server-side OnRep calls were not made (opt-in `onrep=true`), because native OnReps may touch client-only UI.
- Result: pending Luis.
- `{action=recycle}` sets the puppet's `NetCullDistanceSquared` to 1 for 9 s, then restores it, so clients drop and re-create the pawn as on a rejoin. Prepared, not run yet.

## Woodcutting timeline: W1, recorded live (2026-10-25 14:15–14:16 UTC, Luis chopped one oak with an axe)
Recorder: `mod/experiments/tree_watch.lua` (read-only, 1 s poll, 25 m radius).
1. **Standing tree:** `BP_BM_Tree_Oak_02_C`, HP **220**. One chop took it to 110, and at once `bIsStump=True`: the standing tree became the stump. A **`BP_FelledTree_Oak_C`** (HP 105) appeared next to it.
2. **Felled tree** (HP stays 105) spawns **`BP_SplittableLog_Oak_C`** pieces (HP 105) over about 4 s.
3. **Each splittable log** is chopped 105 → 21 → 0 (2 hits). At 0 it yields a **`BP_Log_Oak_C`** (HP 105) and further splittable pieces.
4. **Each `BP_Log_Oak_C`** is chopped 105 → 21 → 0. At 0 it bursts into **`BP_RuntimeSpawnedWorldItem_C` drops**: `ITEM_Resources_Wood_Oak`, **stack 1 each, 6 per log**.
5. **Pickup is by magnet:** drop distances shrink toward the player (1.1 m → 0.7 m, or 10 m → 0) and then the item is gone (collected). Players don't press interact for these.
6. **Stump:** HP 110, overhead swings took it 26 → 0. It disappears and drops **1 more oak log** item.
- So the bot's loop is: find a standing oak (`bIsStump=false`, HP>0) → chop → the felled tree splits on its own → chop every `SplittableLog_*` and `Log_*` within range until gone → collect `RuntimeSpawnedWorldItem` (ITEM_Resources_Wood_Oak) → optionally overhead-chop the stump (+1 log) → next tree.
- Progress check: the bot store count of ITEM_Resources_Wood_Oak. Each drop is a stack of 1, so a stack of 99 is built up in the store.
- Open: whether the **puppet's** magnet component pulls items (it has `BP_Components_ItemMagnet`), and where they go with no player inventory. Test W2 before relying on it; the bot may need to destroy and record items itself.

## Spells (build 26161880, 2026-10-25, live server; no crash, no restart caused)
Modules: `mod/experiments/spell_dump.lua` (X1), `spell_x3.lua` (X3), `spell_x4.lua` (X4, not run), service `mod/body/spells.lua`. Catalog: `data/spells_26161880.json` (52 `UtilitySpellData`, each with `usage` = role / preconditions / use_when / runes / cooldown / route). Crash dumps stayed at 9 throughout; `ping` OK after every step.

**X1, read-only dump (verified; run twice, 14:0x without players and ~14:12 UTC with Luis connected).**
- Reads that work under UE4SS experimental: `FindAllOf("UtilitySpellData")`; `spell.Modules.Modules[i].Module` (TArray of structs → object); `SpellDisplayName`/`PerkName` FText `ToString`; `CooldownDuration`; `CostItems.ItemsCostInfo[] {ItemData, Count}`; `GameplayEffect` TSubclassOf and its CDO fields; soft class `UtilitySpellClass` via `GetObjectID():GetAssetPathName()`; **TSet `ProgressComponent.SpellsUnlocked:ForEach`** (38 entries); TMap `PlayerUtilityMagicComponent.LastCastTimeBySpellData:ForEach` (empty: no cast yet this session).
- Costs/cooldowns (game data, wiki differs in places): Tempest Shield 15 Air / 45 s; Windstep 5 Air / 3 s (cost multiplier attribute `ATT_WindstepRuneCostMultiplierAttribute`); Enchant Weapon Fire/Air/Water/Earth 15 <element> + 5 Astral / **300 s** (wiki: 90 s); Spectral Arrows (`USD_CorruptionArrows`) 15 Astral + 5 Air / 300 s; Magical Mending 20 Earth + 10 Nature / 60 s; Axtral Projection 10 Air + 5 Astral / 45 s; Splinter 10 Earth + 5 Nature / 45 s; Trunk Totem (`USD_PileEmUp`, Woodcutting 50) 30 Nature + 10 Law / 180 s. Full table in the JSON.
- Name mapping confirmed from `SpellDisplayName`: `USD_PileEmUp` = Trunk Totem, `USD_Treequipment` = Bark to Bones, `USD_Harvest` = Uproot, `USD_FishCyclone` = Fishnado, `USD_SpeedupStation` = Overdrive, `USD_FerociousFurnace` = Superheat, `USD_DetectOre` = Summon Stone Spirits, `USD_DetectAnimaVents` = Summon Elemental Spirits, `USD_Farming_Compost` = Mucksplosion. No cost and no perk (internal/unreleased): CabbageRain, EnchantChefsTools, MagicFocus, WeaponBarbs, WeaponPoison, Whetstone; world-interaction: GetWaterFromWaterSource, SiphonAnimaCharge, SiphonRunes.
- Woodcutting spells: Axtral Projection is Aimed and spawns `BP_Spell_AxtralProjection_C` (Movement + Collision + `SpellModule_DamageByEquipment`, expires after 2000 cm; two extra axes with the upgrade perk). Splinter is Placed, a `BP_Magic_Splinter_C` utility spell with a 230 cm sphere and `DamageByEquipment` (`DamageType.Spell.Splinter`). Trunk Totem is Placed, a `SpellModule_Blueprint`. All three run in the spell module graph, so only the modular route (`TriggerModularAbilityForPlayer`, opt-in) can cast them today.
- Magical Mending: Placed; `SpellModule_UtilityMagic` → `/Game/Gameplay/UtilityMagic/PerkSpells/MagicalMending/BP_Magic_MagicalMending.BP_Magic_MagicalMending_C`; native `URepairSpellComponent` (`RepairEquipmentOfNearbyPlayers()`, no args; `SpellConfig{SpellRange, DurabilityTierPercentageMap, UsedItemsCollection}`, `bIncludeInventory/bIncludeLoadout/bIgnoreItemRequirements`). `UItem.Durability` is the per-item value. Not cast yet (catalogued, route `none`).
- Effects: `GE_TempestShield_C` health = `EffectHealthBase` 50 + `EffectHealthPerAttackSkillLevel` 7.5 × Attack level, duration 1 h in-game time (upgraded: 3 h), repulse 500, expiry burst `BP_TempestShieldExplosion_C` (wedge, force 1000, damage 0). Its instance class `BP_TempestShieldGameplayEffectInstance_C` is FX only in BP; MaxHealth is computed natively. Enchant HEEDs: `AdditiveDamageTypes` `DamageType.Magical.{Fire,Air,Water,Earth}`, +0.33 damage multiplier, 300 s time limit.
- **Windstep explosion** `BP_WindstepExplosion_C` template: `Damage 0`, `Force 1000`, Magical, sphere radius **700 cm**, `bDamageByOwner=false`, `bDamageByEquipment=false`, `PredictDamageDurationSeconds 0.125`.
- **Luis's mirror** (PC `BP_PlayerController_C_2147481363`): 38 spells unlocked (all wheel spells except Earth enchant, Fishnado and the internal ones); wheel 4 radials, 38 of 48 slots filled; perks include `PerkV2_Agility_Spell_Windstep_Upgrade` (Wind Stomp) and `PerkV2_Attack_TempestShield_Upgrade`; skill XP (Attack/Agility/Woodcutting/Runecrafting/Construction/Farming about 1,000,000 = max); runes Air 11030, Astral 15636, Fire 16673, Water 18616, Earth 15368, Nature 9669, Law 31545.

**X3, Wind Stomp emulation (spawn path verified safe; stun NOT yet observed).**
- Calls (`spells.lua` route `wind_stomp`): `World:SpawnActor(BP_WindstepExplosion_C, {X,Y,Z}, {0,0,0})` → `ex:SetOwner(puppet)` → optional `ex.DelayedDamageInfliction:StartDelayedDamage(0.0)` → `ex:SetLifeSpan(5)`.
- Runs: 2 canaries with nothing in range (no players connected), then 3 at a Kebbit (`BP_AI_Kebbit_Character_02_C`, 52–87 m from Luis), 2 of those forced. Server stayed up every time. BeginPlay runs on authority (it sets `ServerTimeOfCreation`); the owner reads back; the actor is garbage after 5 s. Log noise per spawn: `FNetGUIDCache::SupportsObject: DominionShape_Sphere ... NOT Supported` (harmless).
- **Effect:** none observed on the Kebbit: HP 39 → 39, `IsStumbling()` always false, no new gameplay tags in 3 s of 100 ms sampling, and `DelayedDamageInfliction.PendingDamage` empty at cast time and through the window. Kebbit `HitReactionConfig`: `bCanStumble=false`, light 100, heavy 9999, knockdown 1000 (Deer: heavy 200, knockdown 1000; Magpie 9999 everywhere). So either the explosion does not select passive critters, or force 1000 does not beat a threshold of 1000, or a 0 s delay applies and clears synchronously. **Still to do:** a Kalphite (hostile, stumble-capable) with Luis watching, plus a hook on `BP_DominionAICharacter_C:OnAIKnockdownState_Begin` or `AiHitReactionsComponent:Multicast_Stumble`.
- UE4SS gotcha: **returning true does not stop `LoopInGameThreadWithDelay`.** Cancel with `CancelDelayedAction(handle)`. One 10 Hz sampler (polls one Kebbit) leaked from the second stomp and runs until the next server restart; it is harmless.

**X4, Tempest Shield via `InstantiateGameplayEffect` on the puppet: NOT RUN (judged risky).** MaxHealth needs the Attack skill level, which lives on a PlayerController the puppet lacks (the null-PC crash class), and the instance replicates FX to clients (the client-freeze lesson). `spell_x4 apply` refuses unless `confirm="offline_canary"` and no player is connected. Run it only with nobody online and Luis's OK.

## Combos verified in game (2026-10-25, about 14:30 UTC, Luis via GFN)
- With `ITEM_Club_Wood` (held class `BP_Club_Wood_C`, equipped with an explicit actor_class), the `attack` handler (`body/combat.lua` BT, Club set `PA_Attack_Club_C`) killed a Kebbit (39 HP) in 4 swings. **Luis saw the combo chain** (different swings in sequence), where before only Attack1 repeated.
- The full 5-step chain and the special (Block Breaker) are not seen yet: the Kebbit died first. Next: a tougher or immortal target.
- The live Skullsplitter fix (`equip` with actor_class) is applied. The default-path fix (LoadAsset + catalog `held_class`, no generic fallback) is in `gear.lua` and takes effect at the next restart.

## NAMEPLATE FIXED: the bot shows "Claude" (verified 2026-10-25, about 14:40 UTC, Luis via GFN)
- **Cause:** clients resolve the nameplate (like chat senders) from the PlayerState's `OwnerGuid` = (AccountGuid, CharacterGuid), looked up in `GameState.DisplayNameComponent.SanitizedCharacterNames`.
  - The bot PS had an **empty AccountGuid** (keyed ","), so the lookup missed and the widget showed its default "Character Name Here".
  - Ruled out: PlayerState name (ChangeName), registry entries with an empty account, PlatformData/PlayerColor, push-model dirty marking, push model off, and client re-creation.
- **Fix:** `bot_ps.OwnerGuid.AccountGuid = host_ps.OwnerGuid.AccountGuid` (UE4SS struct-to-struct assignment = engine copy; never built in Lua), keep the bot CharacterGuid (0C0FFEE1-00C0DE00-0BADF00D-00000001), then make the client re-create the pawn.
  - "Claude" is registered under (Luis's account, bot GUID) (`name_register.lua` / `identity.register`).
  - **Luis: "He spawned in as Claude."** It is effectively like a second character on Luis's account.
- Built into `mod/body/identity.lua` (`copy_account` on spawn and on adopt; `is_registered` now requires an account with a platform id). Takes effect at the next restart; live puppet fixed via `mod/experiments/owner_account.lua`.
- Side effects to watch: the game may treat Claude as owned by Luis's account (claims, permissions). None observed yet.
- **Push model is now OFF** (`Saved/Config/WindowsServer/Engine.ini [ConsoleVariables] net.IsPushModelEnabled=0`, backup at `Engine.ini.bak-pushmodel`). It was not the nameplate fix, but it makes Lua property writes replicate. Keep it unless perf telemetry shows a cost.

## "This server might be modded" warning (2026-10-25)
- The server advertises the EOS session attribute **`ModDetection = 1`** (`LogNetSessionSettings: Setting ["ModDetection"] … value[1]`), alongside `BuildId=254097`, `ServerType=1`, `BetaHash=77`, `JoinCode`, `Vip_ServerName` and others. The client shows the warning when the attribute is set.
- **It is set by the game itself:** there is no ini key, and no reflected symbol in the dump, so the check is native. It most likely detects foreign code in the process (UE4SS via `version.dll`) or modified content. Pre-UE4SS logs have rotated away, so the 0 → 1 change is unconfirmed.
- **Policy:** leave it. The label is accurate and part of Jagex's vanilla-vs-moddable signalling. Don't try to hide it. If the companion ever runs on the group's real server, friends will see the warning.

## Item handling: world items, the puppet's magnet, spawning drops (build 26161880, 2026-10-25, 14:31–14:51 UTC)
Modules: `mod/experiments/item_probe.lua` (probe/canaries), `mod/body/items.lua` (world items), `mod/body/inventory.lua` (bot store), `mod/body/item_skills.lua` (pickup/drop/give). Crash dumps stayed at 10 throughout; the one new dump this period (14:45:24) came from the `speech_direct` experiment, not these modules.
- **World item reads (verified, census with Luis connected):** `BP_RuntimeSpawnedWorldItem_C` kebbit/tree loot: `w.ItemData` (e.g. `ITEM_Resources_Wood_Ash`, `ITEM_Resources_Coarse_Animal_Fur`, `ITEM_Resources_Weeds`), `w:GetStackSize()` = 1, `ItemData.MaxStackSize` = 99 for all three; `MagneticComponentGrantItem`: `bAllowAutoMagnetization=true`, `bAutoMagnetizationEnabled=true`, `AutoMagnetizationCategory=1` (Generic), `ContactRange=50`, `MinTimeBeforeMoving=1.0`, `bHasBeenGranted=false`, `Target=nil`; `SpawnedItem` (`UItem`): `Count`, `Durability=-1`, `GetMaxDurability()=-1`, `NumMasterworkUpgradesApplied=0`, `Guid`. `bCanExpire=true`, `bCacheInWorldItemRuntimeCache=false`.
- **The puppet's `BP_Components_ItemMagnet` is inert (read-only observation):** `MagnetRange=350`, the same as Luis's. Kebbit loot dropped about 2.5 m from the puppet (the attack at 14:29:19–30 killed a Kebbit 1.5 m from it) still lay there with `Target=nil` and `bHasBeenGranted=false` at 14:31. So items are not pulled into the puppet's missing (null) inventory, and the bot must take them itself (the `items.take_world_item` route). `IsActive()` is false on both magnets, so the magnetisation subsystem works natively and evidently picks only real players.
- **`UItemHelperLibrary:SpawnAndLaunchItem_Sync(world, FItemSpawnParameters, Out)` is SAFE to call (offline canary, 0 players, 4 calls, no crash):**
  - The struct goes in as a Lua table with **every** field set (`items.spawn_params`). Null object fields use UE4SS `CreateInvalidObject()` (it exists in 3.0.1, and `IsValid()` is false).
  - **UE4SS gotcha:** an `Out` parameter needs a Lua **table**. Passing `""` raises the Lua error "Tried storing reference to a Lua table for an 'Out' parameter ... no table on the stack" before the native call, so nothing happens. With `{}` the call works and writes `OutFailureReason` (empty) into the table.
  - The call returned `BP_RuntimeSpawnedWorldItem_NoExpiry_C` with the right `ItemData` (Oak Logs), stack 1 and 99, at the requested spot.
  - **With no player connected, the game destroys the spawned item within 50 ms**, in place and even with `bSkipFloorSafetyCheck=true`. It is Garbage-flagged at the first 50 ms sample and at the same location, and every other world item is gone too (`world_items_total=0`). So persistence and client view can only be tested with Luis online.
- **Still to verify with Luis (needs his go-ahead, warned):**
  - (1) `item_probe drop confirm="luis_ok"`: 1 oak log 3 m from him. Does he see it, can he pick it up, and is it +1 in his inventory?
  - (2) The `pickup` handler on a real drop. Does the item vanish on his client with no ghost, and does `inventory` show +1?
  - Flip `items.ROUTES.spawn_sync.verified` after (1).

## On-demand speech and the UE4SS nested-userdata crash (build 26161880, 2026-10-25, 14:35–14:50 UTC)
- **Net id sources (read-only, verified live, Luis connected):** `UDominionRuntimeBlueprintLibrary:ConvertUniqueNetIdToJsonString(FUniqueNetIdRepl)` on `/Script/Dominion.Default__DominionRuntimeBlueprintLibrary` turns a net id into a string. It is safe with a top-level struct userdata.
  - Luis's `PlayerState.UniqueID` (APlayerState, 0x2D0) = `OwnerGuid.AccountGuid.NetIdPrimary` = `RedpointEOS:000286bf...`; `NetIdSecondary` = `STEAM:7656...`.
  - The bot PS: `UniqueID` is empty, and its AccountGuid holds the copy of Luis's (identity).
  - `FChatPlayerSenderData` = {PrimaryNetId, SecondaryNetId (FUniqueNetIdRepl), CharacterGuid, PlayerId, Color}. `FChatPlayerFilterData` = {SenderId, `TArray<FUniqueNetIdRepl>` ReceiverIds}.
  - No reflected property anywhere holds an `FChatMessageData`/`FChatPlayerSenderData`, so there is no persistent template.
  - Not yet captured: a genuine line's PrimaryNetId/SecondaryNetId/SenderId and the ReceiverIds count. `speech_direct capture` records them on the next player line (the hook is registered once per run).
- **UE4SS marshalling (source read at the installed commit 83330635; main is identical):**
  - The UFunction call buffer is `Memzero`'d, never `InitializeValue`'d nor `DestroyValue`'d.
  - A table param goes through `convert_lua_table_to_struct`, which runs each field's pusher with `stored_at_index = -1`. Scalar pushers honour it.
  - **BUG: `push_structproperty`'s userdata branch calls `get_userdata<UScriptStruct>()` with the default `force_index = 1`, ignoring `stored_at_index`.** For a top-level param, index 1 is that param, so it works (the relay passes a whole genuine `FChatMessageData`). Property assignment (`a.B = ud`, `__newindex`) is also fine: self and key are removed first, so the value is at index 1 (identity's AccountGuid copy).
  - **A struct userdata nested inside a Lua table reads the wrong stack slot (the outer table) and dereferences garbage.** It is the only pusher with this bug (`LuaUObject.cpp:784`). UObject, FName, FString, FText, TArray and soft-pointer userdata use `stored_at_index` and are fine nested, which is why `BP_PerformAttack({Data=<UObject>, ...})` works.
  - Also: UE4SS `TArray` `__index`/`__newindex` past `Num` calls `AddZeroed` (reads past the end grow the array), and there is no `RemoveAt`.
- **CRASH (my test, 14:45:24 UTC, `crash_2026_10_25_15_45_24.3244819.dmp`):** `Server_SendChatMessage({SenderData={PrimaryNetId=<ps userdata>, ...}}, {SenderId=<ps userdata>})`.
  - Stack: UFunction call → `push_structproperty` → (table) → `push_structproperty` → (table) → `push_structproperty+0x71f` AV. This happened before ProcessEvent, so no message was sent.
  - Last breadcrumb: `speech_direct.Server_SendChatMessage`. The watchdog restarted the server at 14:45:39; Luis was disconnected and the puppet was gone (autospawn off).
  - **R3 (PredictDamage `TArray<FTypeDamage>`) has the same frames and is very likely the same bug.**
  - **Rule: never put a struct userdata inside a Lua table passed to UE4SS. Scalars-only tables are fine; copy structs only by property assignment or as a top-level param.**
- **Route v2 (built, UNVERIFIED in game):** `body/speech.lua` `send_direct` / `DW_SAY_MODE=direct`.
  - Call `Server_SendChatMessage` with SCALAR-ONLY tables.
  - A one-shot PRE-hook on the same function then copies `NetIdPrimary`/`NetIdSecondary`/`UniqueID` into the live param buffer by property assignment.
  - Evidence that pre-hooks fire for Lua-initiated calls and see the buffer: `hooks.lua`'s pre-callback logged the relay's re-sent text (`mod_20261025T133955Z.jsonl`, 13:41:42).
  - Still unproven: that the native implementation reads the edited buffer. `speech_direct prove` checks this read-only (`GetCharacterDisplayName` with an empty account, patched by a pre-hook → must equal the host's own name), and `send` refuses until it passes.
- **Map and compass presence (read-only, verified live):**
  - Players come from `AGameplayObjectRegistry.PlayerCharacters` (`TArray<FPlayerCharacterData>`, ReplicatedUsing `OnRep_PlayerCharacters`, not SaveGame). The element is {Location, RotationByte, OwningCharacterGuid, OwningPlayerUniqueID, OwningPlayerName, Color, Identifier}.
  - The registry is also `UGameplayObjectSubsystem.ObjectRegistry`. `UMapUIAPI` and `UCompassWidget` hold it, and compass icons are keyed by FGuid; `EMapIconType.OtherPlayerCharacter = 2`.
  - Live: **the bot PS is in `GameState.PlayerArray`** ("Claude", `bIsABot`), but **the registry had only Luis** ("Zezima", location tracking his pawn). The puppet has the registry pointer (`ADominionPlayerCharacter.GameplayObjectRegistry`).
  - Server log: the puppet's native `OnWorldLoadedAroundCharacter` runs at spawn (cells already loaded) and again in `PossessedBy`, both times before identity attaches the PS → `DominionPlayerState must be valid`. For Luis it runs about 5 s after possession, with no warning.
  - Hypothesis (UNVERIFIED): that function adds the registry entry, so linking the PS to the AIController before `Possess` (APawn::PossessedBy copies `Controller->PlayerState`) would let the game register the bot itself. That needs a puppet respawn (puppet.lua), and the native path may touch PlayerController-only state.
  - Built (UNVERIFIED): `body/presence.lua` appends one scalar-only entry (Identifier `0C0FFEE1-00C0DE00-0BADF00D-0000A11E`) and updates Location/RotationByte every second. Experiment: `presence_test add confirm=true`.

## Spells wired live + reflex rules (build 26161880, 2026-10-25, about 15:45-16:10 UTC+1; no crash caused, dumps stayed at 10)
- **Startup (run `mod_20261025T144539Z`):** `main.lua`'s SPELLS + REFLEX RULES block loaded. The catalog path came from `DW_MOD_LOG_DIR` (`C:\gameserver/data/spells_26161880.json`, 52 spells, because `DW_REPO_ROOT` is only set by `start_server.ps1` from now on). Policy `mirror_budget` (the inventory store was ready). Rules were installed as the first combat `on_tick` hook. Spells reflexes: Tempest Shield (`self_effect`) and Windstep (`wind_stomp`) are both **OFF**, because the catalog `routes[r].verified` is false.
- **Bridge handlers verified live (nobody online):** `capabilities` lists `cast`, `spells`, `spell_tactics`, `set_reflex_rule`, `list_rules` and `clear_rule`.
  - `spells {compact}` returns `[]`: all 52 spells answer `not_implemented` (route not verified).
  - `cast` with no puppet answers `companion_down`.
  - `set_reflex_rule` (kalphite, telegraph, evade + Windstep at self) returns the rule read back, `persisted=true`, and a warning that Windstep's route isn't verified. The bot state file kept `v`, `gear` and `inventory` and gained `reflex_rules {v, next_id, by_enemy}`.
  - An unknown trigger answers `cant_sense`.
  - `clear_rule {all}` emptied it again (`by_enemy` is `{}`, `next_id` is 2).
- **Telegraph source:** the server log line `DominionAiAttackComponent: AUTH ATTACK : TELEGRAPH ... TimeUntilEvent` and `EvadeAttack: OnTelegraphDamage / PredictPointDamage` are **native**. Neither name is in the CXX dump, so there is nothing to `RegisterHook`.
  - The reflected attack signals are `UAiAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackClassId, AttackId, bFromCombo)` (NetMulticast, at attack start), `AiAttackTicketsManager:OnAiAttackStarted(AI)` (delegate handler), and the BP event `BP_AiAttackComponent_C:BP_PreemptParryWindowOpening(ParryWindowLength, AttackData)` (parry window, near the hit).
  - `body/rules.lua` **polls** `ADominionAICharacter.AiAttackComponent.CurrentAttack.AttackData` (`FAiAttack`, DOM:14612) instead, as a property read with no hook. A nil-to-set change is one telegraph event.
  - Kebbit log timing: `TryPerformAttack` at t, TELEGRAPH at t+1.335 s, damage at t+1.35 s. Attack start therefore gives about 1.3 s of warning.
  - **UNVERIFIED:** that `CurrentAttack.AttackData` is set on the server during an attack. No AI was loaded to read (nobody online).
  - Next: `debug_run rules_probe {action=watch, seconds=30}` while Luis fights. It logs `rules_probe_attack`.
- The player dodge (`UPlayerEvadeComponent`) has no reflected start function, only `Multicast_StartEvade(int32, bool, FRotator)`, which is visual and takes a struct argument (rule 4). So the rule action `evade` is a 4 m `MoveToLocation` away from the attacker.

## Gather: the puppet's tool swing, the emulated hit, resources (build 26161880, 2026-10-25, 14:31-14:38 UTC, Luis watching via GFN)
Modules: `mod/experiments/gather_probe.lua` (discovery), services `mod/body/sense.lua`, `watch.lua`, `hitcheck.lua`, data `mod/body/resource_profiles.lua`, loop `mod/body/gather.lua`. No crash from these steps (dumps 9 before and after; the 14:45 crash was `speech_direct`).
- **A puppet's hatchet swing reaches a tree but the tool gate reads it as UNARMED.** `BP_PerformAttack(BP_Player_Axe_Woodcut1, {Data=PA_Attack_Hatchet CDO, PlayerOwner=puppet, EquipmentHand=1, DesiredActionTarget=oak})` at 1.1 m, with the Adamant logging axe held (`gear.read` and the native `GetHeldEquipmentDataRight()` / `HeldEquipmentActor:GetHeldEquipmentData()` all return `ITEM_Logging_Axe_Adamant`, category `Item.Equipment.Tool.Hatchet`):
  - hooks on `BP_DamageModifier_SpecificWeapon_C` (DA_HatchetOnly_Tier3) fired `GetHeldEquipmentThatInflictedDamage` (Source = the puppet pawn, HeldEquipment = nil), `IsDamageCausedByUnarmedAttack` (true), then `ModifyDamage` (Amount 10, Instigator = puppet). `IsEquipmentOfSufficientTier` / `IsEquipmentCorrectCategory` were never called. HP stayed 220 (3 tries).
  - **Luis saw it:** the bot swung the axe at the oak with no effect, then killed a Kebbit with the same axe (11 chops + 2 overhead specials, `attack` handler). Creatures have no tool gate.
  - Cause (inference, strong): `FPlayerActionInstance.ActionGranter: UEquipment*` (DOM:5721) is nil in our call; the puppet has no `UHeldEquipmentItem`. At 3.8 m the swing never reached the pipeline (no contact).
  - UE4SS note: for these BP functions the Lua callback ran once, after the function (out params filled); the post callback never fired.
- **Emulated hit works:** `tree.HealthComponent:DecreaseHealth(84, "dw_gather")` (84 = attack damage 10 x Adamant damage multiplier 8.4, the exact per-hit damage Luis did on logs in W1) on a standing oak: 220 -> 136, then 136 -> 110 with the split: `bIsStump=true` (HP 110), `BP_FelledTree_Oak_C` (HP 105), `BP_SplittableLog_Oak_C` (HP 105, log type 1) and one `ITEM_Resources_Wood_Oak` world item (stack 1) next to the stump. A minute later the felled tree was gone and the splittable log remained. Luis's own chop went 220 -> 110 in one hit (crit or perk); ours needs 2.
- **Trees are foliage until converted:** `Default__InteractableFoliageFunctionLibrary:ConvertFoliageNearbyLocation(puppet, loc, r, true, false, puppet)`: 47 trees within 50 m in 28 ms, 323 within 150 m in 168 ms (30 -> 353 FellableTree actors). **Undamaged converted trees revert within seconds** (new actor ids on every conversion; a MoveToActor target vanished mid-walk); the damaged one stayed. Hence `sense.relocate` (convert at the remembered position, find the same species within 2 m).
- **Gates and HP (live census):** oak `BP_BM_Tree_Oak_0{1,2}_C` HP 220, `SplitDamageFraction` 0.5, `DamageModifiersWhenTree` = `DA_HatchetOnly_Tier3` (RequiredTier 3, `Item.Equipment.Tool.Hatchet`) + `DA_ResistantToSpecial` (`BP_DamageModifier_MultiplyBasedOnAttackProperties_C`); stump: `DA_HatchetOnly_Tier3`; the stump's `ItemDropOnDestructionComponent` = 1 x oak log. Ash `BP_BM_Tree_Ash_0{1,2,3}_C` HP 160, `DA_HatchetOnly` (tier 1), splittable ash log HP 80. Around Brynmoor: 335 ash vs 18 oak after converting 150 m.
- **Rocks:** `BP_OreNode_Stone_C` is a `DestructibleMiningRock` (136 loaded): HP 75, `DA_PickaxeOnly` (tier 1, `Item.Equipment.Tool.Pickaxe`), drops `ITEM_Resources_Stone` 10-16, `bDestroyActorOnZeroHealth=false`. `BP_MiningRock_RuneEssence_Static_A_C`: HP 60, 5 x `ITEM_Rune_Essence`. `BP_RuneEssenceGeyser_*_C` are `AOreNode`s (no HealthComponent; NodeHealth 1, 3/4 chunks). Details: `docs/research/2026-10-25-mining.md`.
- The puppet's `BP_Components_ItemMagnet`: `MagnetRange` 350, **inactive** (it never pulled the oak log lying 2 m away).

## Drop verified in game (2026-10-25, about 15:20 UTC, Luis via GFN)
- `UItemHelperLibrary:SpawnAndLaunchItem_Sync` (route `spawn_sync`; scalar-only params plus a Lua table for the Out param) dropped one `ITEM_Resources_Wood_Oak` as `BP_RuntimeSpawnedWorldItem_NoExpiry_C` near the bot. **Luis saw it and picked it up normally**; his client stayed responsive. `items.ROUTES.spawn_sync.verified = true`.

## Pick up + give verified; item-substitution bug (2026-10-25, about 15:25 UTC, Luis via GFN)
- `pickup` and `give` work live: the bot collected the dropped oak logs and gave 2 to Luis at his feet (`give` result: world item spawned at the player).
- **Bug:** "claude pick up the sticks". Sticks are ground gatherables (`BP_Spawner_AshBranch_*`, BaseInteractableResource), not in `nearby_items`, so Haiku picked up the only visible item (the logs it had just given Luis).
  - Fix (brain): `PickupArgs.item` must be set to what the player named; never substitute; say "I can't see any X".
  - Fix (body, gather agent): sense ground gatherables plus a pickup route for them.
- Luis's woodcutting observations of the gather agent's self-test:
  - The tree WAS felled. It used only Overhead Chop.
  - It ignored the felled trunk and logs and went to a new tree; it did chop the stump; then it idled far away.
  - All forwarded to the gather agent.

## On-demand speech v2: safe but not delivered (2026-10-25, about 15:35 UTC, Luis via GFN)
- `speech_direct prove` PASSED: the pre-hook patch of the net ids into the live `Server_SendChatMessage` call is read by native code (`patched=Zezima == control`).
- `send` returned ok and the server stayed healthy; **Luis's client did not freeze** (unlike the hand-built Client_* RPC case), but **no chat line appeared**.
- Prime suspect: `FChatPlayerFilterData.ReceiverIds` was empty (routing to nobody). The presence agent is capturing a genuine filter from a real message next.

## Melee hitboxes: why swings whiffed (2026-10-25, read live via `mod/experiments/hitbox_probe.lua`)
- Hits come from `UPlayerAttackData.TimedDamageShapes`: an array of {TimeOffset (s into the attack), DamageShape}. The shape is a `UDominionShape_{Arc,Box,Capsule,Sphere,Wedge}` with Offset/Pivot/Scale/RotationOffset plus shape fields, relative to the attacker. The melee component also has **camera-based aim assist** (`MaximumAngleAimAssist`, `ScreenSpaceRadius`), which the puppet lacks (no camera).
- **Axe Chop** (`BP_Player_Axe_Woodcut1_C`, primary): Wedge **Depth 115 cm**, TopAngle 80°, **AngleOffset 35°** (skewed to one side), ZHeight 200; hits at **0.55 s**; 10 dmg.
- **Axe Overhead Chop** (`BP_Player_Axe_Woodcut2_C`, special): Wedge Depth 170 cm, **TopAngle 15° (±7.5°)**, AngleOffset 0, Offset Z −40; hits at **0.84 s**; 10 dmg.
- Luis saw the bot "overhead chopping thin air". The target was outside the narrow wedge. **Fix (generic):** before each swing, read the chosen attack CDO's shapes, then rotate and step so the target's position (re-read each swing; logs roll) lies inside the shape at its TimeOffset. Verify the HP change afterwards (hitcheck). Applies to every weapon and tool.

## The bot counts as a player for the night skip (2026-10-25, Luis via GFN)
- Since the bot got a `DominionPlayerState` (in `GameState.PlayerArray`, nameplate "Claude"), **Luis confirms it counts as a character/player**, so it blocks "all players sleeping" from passing the night.
- Needed: a `sleep` skill (nearest bed via sense → go_to → `Claim/Sleep(puppet)`; else cast Summon Shelter on flat ground), plus a reflex to sleep when Luis sleeps, plus an interim debug flag so the bot doesn't count. Spells agent assigned.

## Speech: genuine filter captured (2026-10-25, about 15:55 UTC)
- A genuine `Server_SendChatMessage` from Luis carries `FChatPlayerFilterData` {SenderId = his RedpointEOS id, **ReceiverIds = [his RedpointEOS id] (1 entry)**}, and SenderData {Primary = RedpointEOS id, Secondary = STEAM id, PlayerId 256, CharacterGuid, Color}.
- The first direct send had **0 ReceiverIds**, so the server routed it to nobody. Second send: `receivers=true` (each connected player's PlayerState.UniqueID copied by array-element assignment in the pre-hook). No crash; awaiting Luis's visual result.

## ON-DEMAND SPEECH WORKS (2026-10-25, about 15:56 UTC, Luis via GFN)
- `speech_direct send` with `receivers=true` showed **"Claude: Claude here - can you hear me now?"** in Luis's chat with **no triggering message**. Luis: "Yes could see his message." No crash, no freeze.
- **Route:** `Server_SendChatMessage` on a connected player's PlayerChatComponent with scalar-only tables (bot GUID, PlayerId, colour, text). A one-shot pre-hook copies the live net ids (PrimaryNetId/SecondaryNetId from the host PS, SenderId) and fills **ReceiverIds with every connected player's PlayerState.UniqueID** (array-element assignment = safe property copy; not R15).
- The name resolves to "Claude" via the (host account, bot GUID) registry entry.
- Made the default: `start_server.ps1` sets `DW_SAY_MODE=direct` (relay remains the fallback). Effective at the next restart.

## Night skip and sleep (build 26161880, 2026-10-25, about 16:30-16:45 UTC+1, Luis online; no crash, dumps stayed at 10)
- **Luis confirmed in game that the bot blocks "all players sleeping".** It has a `DominionPlayerState` in `GameState.PlayerArray` (`bIsABot = true`). So `bIsABot` does **not** exclude it.
- **How the game decides (dump, read-only):** the skip is native.
  - `UPlayerSleepSubsystem` (a `UTickableWorldSubsystem` with no reflected members) and `ADominionGameMode.OnAllPlayersSleeping` (delegate).
  - Per player: `ADominionPlayerCharacter.PlayerRestComponent` (`UPlayerRestComponent`, BP `BP_Components_Rest_C`, held in the character property `BP_Components_Sleep`). It has `IsSleeping` (replicated, `OnRep_IsSleeping`), `CurrentRestingAreaActor/Component`, `IsInTimeframeForSleep()`, `IsWaitingForSleep()`, `StartSleeping()`, and `GetWaitingToSleepText(InstigatorName, bIsInstigator, NumPlayersInBeds, NumTotalPlayers)`. So the UI counts "players in beds / total players".
  - Beds: `UBedComponent : URestingAreaComponent` with `CanSleep / Sleep / StopSleeping / Claim (ADominionPlayerCharacter*)`, `IsClaimedByAnyPlayer`, `IsClaimedByPlayer`, `GetClaimingCharacterName`, and `bRequiresClaimingToSleepIn`. `URestingAreaComponent` adds `Rest / StopResting / CanRest`.
  - Time: `/Script/Dominion.Default__InGameTimeFunctionLibrary:IsNighttime(ctx)` and `GetInGameTime(ctx)` (FTimespan; `Ticks / 3.6e10` gives hours) both read fine live. `GetTimeOfDusk/Dawn` return nothing readable.
- **Live reads (`experiments/sleep_probe`):** in-game 07:11, then 11:18 in the next run. No `BedComponent` or `RestingAreaComponent` was loaded near Luis (his beds are elsewhere and unloaded). Both rest components were readable (`IsSleeping = false`). PlayerArray: Zezima (`bIsABot = false`) and Claude (`bIsABot = true`); `bIsSpectator`/`bOnlySpectator` are false on both.
- **Which per-bot flag lets Luis pass the night: NOT YET KNOWN.** It needs a night with Luis in bed. Candidates are built (`body/sleep.lua`, armed at startup since the 16:32 restart):
  1. Rest flag: the puppet's `PlayerRestComponent.IsSleeping = true` (property write, no OnRep). The sleep reflex does this automatically when Luis starts sleeping and no free bed is within 25 m.
  2. `night_skip {mode=spectator}`: the bot PlayerState's `bIsSpectator` and `bOnlySpectator` set to true.
  3. A real bed: `BedComponent:CanSleep(puppet)`, then `Sleep(puppet)`. It never takes a bed someone else claimed.
  - Record the result here.
- Summon Shelter (`USD_SummonShelter`): a Placed spell whose `SpellModule_UtilityMagic` spawns `BP_Magic_SummonShelter_C` (`AUtilitySpell`, caster from `GetCaster()`). It only runs through the module graph, so there is no safe route yet and the sleep skill's no-bed fallback is the rest flag.

## Cast route canary: self_effect with Fire Spirit (build 26161880, 2026-10-25 about 16:44 UTC+1; no crash)
- **Choice:**
  - `USD_FireSpirit` (`GE_FireSpirit_C` on SpellOwner, instance `UFireSpiritGameplayEffectInstance`, which drives an `AFireSpirit` light bound to `TargetCharacter`; 3 h in-game, no damage, nothing on others).
  - Cast through `GameplayEffectsComponent:InstantiateGameplayEffect(class, nil, false)`, the `self_effect` route. It takes plain args, skips the spell module graph (no `SpellModule_CostItems` null-PC inventory read, R8), and avoids Tempest Shield (MaxHealth reads the Attack level from a PlayerController the puppet lacks).
  - Tempest Shield now carries `needs_own_test` in `spells.lua`, so proving the route does not enable it.
- **Run (`experiments/cast_test cast`):** the puppet was walked about 14 m from Luis first. A `FireSpiritGameplayEffectInstance` appeared in the puppet's `ReplicatedInstances` (4 to 5 instances); the server stayed up and `ping` was fine.
  - No `AFireSpirit` actor was visible server-side after 5 s (it is probably a client-side cosmetic, spawned from the replicated instance).
  - **Pending: Luis's eyes**, whether a fire-spirit light is floating by Claude. Only after a "yes" set `routes.self_effect.verified = true` in `data/spells_26161880.json` (and `spells.USD_FireSpirit.verified_in_game = true`).
  - To remove it: `cast_test {action=remove, confirm=true}`.

## Lodestones, map regions and travel (build 26161880, 2026-10-25, about 15:35-15:50 UTC, read live via `mod/experiments/travel_probe.lua`; Luis connected; no crash, dumps stayed at 10)
- **Lodestones are world objects, not per-player unlocks.**
  - `AGameplayObjectRegistry.Lodestones` (`TArray<FLodestoneData>` {Location, RespawnLocation, Identifier}, OnRep, replicated for the map) lists every lodestone in the world.
  - This dev world has exactly one: `5E74232B4126EDE0BAEFF9856FFD03C6` at `[50.65, 1890.26, -36.33]` m (Temple Woods). Its RespawnLocation is the same point plus 1.45 m (Z): this is where a teleporting player arrives.
  - The loaded actor is `BP_WorldLodestone_C` (`AWorldActor.DisplayName` = "Lodestone", `InteractionComponent.InteractionPrompt` = "Teleport", `InteractionUnavailableAdditionalDescriptionText` = "Inactive"). It has the same `GameplayObjectRegistryIdentifier` and `TeleportLocationOffset` (0, 0, 145 cm).
  - Its `ULodestoneComponent.GameplayObjectRegistryIdentifier` reads all zeros. The wiki says most lodestones are player-built (32 Stone, 20 Rune Essence, 1 Vault Core, Construction 80), and that the Temple Woods one turns active when the first one is built.
- **Luis's side (READ ONLY):**
  - Luis's `BP_PlayerController_C` has `LodestoneTeleportationComponent` (`BP_Components_LodestoneTeleportationComponent_C`) with `bEnableTeleportationCost=true`, cost item `/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Law`, `bHideMapAfterTeleportationStarted=false` and `bShouldTryDamageOnTeleportComplete=false`.
  - The component's BlueprintPure `CanTeleport(FromId, ToId)`, `GetTeleportationCost` and `CanAffordTeleportationCost` all work from Lua with **scalar-only FGuid tables** {A,B,C,D} (R15-safe; verified).
  - With a single lodestone, `CanTeleport(x, x)` = false, cost = 1, afford = true. So the per-player gate is the game's own `CanTeleport` rule, and travel.lua counts a lodestone as unlocked when another registered lodestone can reach it. **Proving a true `CanTeleport` needs a second (built) lodestone.**
  - `CalculateTeleportationCost(Distance, Weight)` (const BlueprintNativeEvent) gives 8000 cm/400 → 2, 800000 cm/0 → 4, 800000/400 → 164, and is capped at 999. It is nonlinear and is not the wiki's formula.
  - Luis's `RevealedMapFogComponent`: `CurrentMapRegion` = Temple Woods (RegionID 1), and `RevealedMapRegionsBitmap` = 268435455 (0x0FFFFFFF, 28 bits). The bit-to-RegionID mapping is UNVERIFIED. `RevealedMapIconsComponent.RevealedLandmarkNames` (TSet) read back empty, probably because UE4SS has no TSet ForEach.
- **Map regions** come from `BP_MapRegion_C` actors in the persistent level, which are always loaded on the server. There are 31 of them, each with `RegionID`, `RegionName` (FText), `PowerLevel` and a closed `BoundarySpline` (6-90 points, read with `GetNumberOfSplinePoints`/`GetLocationAtSplinePoint(i, World=1)`/`GetLocationAtSplineInputKey`).
  - By id: 1 Temple Woods, 2 Bramblemead Valley, 3 Whispering Swamp, 4 Fractured Plains, 5 Stormtouched Highlands, 6 Bloodblight Swamp, 7 Bleakfields Valley, 8 Hope's Fall, 9 Lake of Lost Souls, 10 Coalridge Pass, 11 Silverthorn Keep, 12 Dragons' Run, 13 Witchwillow Range, 14 Emberwood, 15 Forgotten Temple, 16-25 the Dowdun Reach areas (The Approach, Library, Courtyard, Menagerie, Garrison, Nexus, Pastures, Cathedral, Bastion, Grand Hall), 26 Alcarrid Oasis, 27 Dunes of Uzzer, 28 Manafem Plains, 29 The Burning Spire, 30 Rasthin's Rest, 31 Scorned Wilderness.
  - **There is no "Fellhollow" region in this build.** It is named only in a wiki changelog, so it is probably a newer area or a sub-area name. **Corrected 2026-10-26:** Fellhollow is a *province*, not a map region; see "Provinces" below.
  - The polygons overlap, so the smallest one containing the point wins (`travel.region_at`). Live: `[2100, 400]` → The Library, `[2200, 1850]` → Manafem Plains, `[-7000, 7000]` → Scorned Wilderness, `[5000, 5000]` → none.
  - `BP_RegionLabelActor_C` (`MapRegionIconComponent.LabelText`) gives 33 map labels (with `\r\n`). Some of their positions are in map space and do not match the region polygons, so they are not used.
  - `AGameplayObjectRegistry.Landmarks` has 558 entries (category 3 = NPC/lore 248, 5 = anima vents 239, 6 = shrines/urns, 8 = kebbit burrows, 11 = agility courses such as "Tower Climb", "Fractured Ruins", 1 = the boss altar). Mostly `InternalName` = None; the useful text is `UserVisibleDescription`.
- **The server streams World Partition cells only around players.**
  - Only 2 `LandscapeStreamingProxy` tiles with bounds were loaded (252 m squares; `GetActorBounds(false, out origin, out extent, false)` works from Lua with empty tables as out params). There were 5-9 `_Generated_` cells, and all 18 AI characters were within 107 m of Luis.
  - A puppet teleported into an unloaded area would fall, and a fall death is the R1 unpossess path. So `travel` only teleports to loaded destinations, and a settle check rolls the teleport back on a fall.
  - Far teleports would need a `UWorldPartitionStreamingSourceComponent` on the puppet (UE5 docs: it makes any actor a streaming source). Not built; it needs an offline canary.
- **Puppet teleport, verified live (15:48:02 UTC):**
  - `K2_TeleportTo({X,Y,Z}, {Pitch=0, Yaw, Roll=0})` (scalars only) moved the puppet 104 m from `[107.39, 1803.25, -30.04]` to exactly the arrival point `[50.65, 1890.26, -34.88]`.
  - After 1 s it was standing at Z -35.05 (no fall). The nav probe `MoveToLocation` +1.5 m returned 2 (RequestSuccessful).
  - A concurrent gather_test loop then walked it 25 m from the pad: **AI nav keeps working after a teleport.** Later 2 m moves returned 2.
  - The puppet then stuck at `[65.8, 1870.3]` inside the Temple ruins (dense StaticMeshActors of the lodestone's own UAID family). `go_to` back to the open spot accepted the request but made only 6 m (path_blocked after 3 reissues). Some 10 m destinations there fail to project (0).
  - So walking out of the Temple Woods lodestone pad is blocked by geometry or navmesh there. That is a navigation issue at that spot, not a teleport issue.
  - Recovery: `travel_probe back` (puppet.teleport_near Luis). Separately, `MoveToActor(Luis)` fails (REQ 0) at Luis's own spot, so he is standing off-navmesh (on a structure?).
  - **Pending Luis's eyes:** did Claude vanish and appear at the lodestone? (At 15:48 Luis was about 75 m away.)
- **Route decision (search-before-building, 2026-10-25):**
  - Need: teleport the puppet to a lodestone like a player does.
  - Searched: the wiki (Lodestone page), Whisper of the House and Destructoid fast-travel guides, Nexus (no Dragonwilds teleport mod found), Epic K2_TeleportTo docs, UE World Partition streaming-source docs.
  - Decision: **adapt**. `K2_TeleportTo` to the registry's RespawnLocation, plus a crowd offset of 150 cm when a player stands on the pad.
  - `TeleportationSubsystem:TeleportWithParams` was rejected: it takes a delegate and drives a PlayerController's loading screen and client RPCs, which the puppet lacks (R1 class). `UBaseTeleportationComponent::Server_TryTeleport` was rejected too: it lives on a PlayerController.
  - Sources: https://dragonwilds.runescape.wiki/w/Lodestone , https://www.whisperofthehouse.com/runescape-dragonwilds/fast-travel , https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/AActor/K2_TeleportTo , https://docs.unrealengine.com/5.1/en-US/PythonAPI/class/WorldPartitionStreamingSourceComponent.html
- **Built:** `mod/body/travel.lua` (`travel`, `where`, `lodestones`; registered in main.lua's TRAVEL block, so it **needs a restart**). Tests are in `mod/tests/test_travel.lua` (22).

## Provinces: the 31 map regions are sub-regions of 6 provinces; NPCs have one copy per province (build 26161880, 2026-10-26; offline: dump + wiki mirror)
- **Luis's fact (2026-10-26):** NPCs such as Zanik and Vannaka exist as several copies, one in each big region (province). In Brynmoor you see only one copy, but they also exist in Ghornfell (e.g. Stormtouched Highlands), Fellhollow, Dowdun Reach and so on. This replaces the earlier unverified guess in brain/places.py and build_places.py that "an NPC moves between its spots with quest stages".
- **Province names = the game's own `EQuestRegion` enum** (`dumps/26161880/luatypes/Dominion_enums.lua`; used by `FQuestData.QuestRegion` and `QuestListItemTooltip.QuestRegionToTextMap`): 1 Brynmoor, 2 Ghornfell, 3 Fellhollow, 4 Dowdun_Reach, 5 Umbral_Sands, 6 Scorned_Wilderness. Asset folders match this split: `/Game/Gameplay/Quests/FH_Quests/` (Fellhollow), `UmS_Quests/` (Umbral Sands, e.g. `Quest_UmS_Vannaka`), `/Game/Gameplay/NPCs/Fellhollow_NPCs/`, the `/DowdunReach/` plugin, and `ScornedWilderness/`.
- **No reflected parent link:** `AMapRegion` has only RegionID, RegionName, PowerLevel, BoundarySpline, Day/NighttimeExposureValue, `MapRegionTag` and `QuestConversationEntryTag` (both FGameplayTag). There is no province, zone or parent property, and `UMapRegionIconComponent` (the map labels) has only label styling. The two tags have never been read; if `MapRegionTag` is hierarchical (`…<Province>.<Area>`), it is the game's own mapping. Live check `tools/live_checks/places_region_tags.json` (places.lua now reads both tags, read-only; dry-run valid, pending). `tools/build_places.py` prefers a province named in the tag over the wiki.
- **Sub-region → province mapping (from the wiki mirror, names only):**
  - Every region has its own infobox `location:` (for example https://dragonwilds.runescape.wiki/w/Temple_Woods), and the lists at https://dragonwilds.runescape.wiki/w/Ashenfall#Brynmoor (and #Ghornfell, #Fellhollow, #Dowdun_Reach, #Umbral_Sands) agree with them.
  - **Brynmoor:** Temple Woods, Bramblemead Valley, Whispering Swamp.
  - **Ghornfell:** Fractured Plains, Stormtouched Highlands, Bloodblight Swamp.
  - **Fellhollow:** Bleakfields Valley, Hope's Fall, Lake of Lost Souls, Coalridge Pass, Silverthorn Keep, Dragons' Run, Witchwillow Range, Emberwood, Forgotten Temple.
  - **Dowdun Reach:** The Approach, The Library, The Courtyard, The Menagerie, The Garrison, The Nexus, The Pastures, The Cathedral, The Bastion, The Grand Hall.
  - **Umbral Sands** (from the Ashenfall list; these pages have no infobox): Alcarrid Oasis, Dunes of Uzzer, Manafem Plains, The Burning Spire.
  - **Scorned Wilderness:** the region of that name (the region is named after the province; the wiki infobox says only "Ashenfall"), plus Rasthin's Rest. Rasthin's Rest is **inferred** from geometry: its polygon overlaps only the Scorned Wilderness polygon, both are power 8 and far off the main continent, and the wiki's Regicide page says that after the Scorned Wilderness gate you "speak to Zilyana in Rasthin's Rest".
  - **"Stormtouched Highlands" is a sub-region** (of Ghornfell), not a province, even though players name it alongside the provinces.
  - A cross-check web search agrees (https://dragonwilds.runescape.wiki/w/Brynmoor , https://dragonwilds.runescape.wiki/w/Ghornfell , https://gamever.io/knowledge-base/ashenfalls-five-regions-in-order-power-levels-hazards-and-what-gates-each-one). The wiki counts 5 regions; the game's enum adds Scorned Wilderness (the raid).
- **The data agrees with Luis:**
  - **Vannaka:** 4 registry spots, one per province: Temple Woods (Brynmoor), Stormtouched Highlands (Ghornfell), Bleakfields Valley (Fellhollow), The Courtyard (Dowdun Reach). The wiki's Vannaka infobox lists the same areas, except it says The Library.
  - **Zanik:** 6 spots: Brynmoor 2 (Temple Woods and Bramblemead Valley; the wiki lists both), Fellhollow 1, Dowdun Reach 1 and Umbral Sands 2. So a province can hold more than one spot with the same name. Which one he stands at is unknown until seen.
  - **Doric:** 4 spots, one each in Brynmoor, Ghornfell, Fellhollow and Dowdun Reach.
- **Built:**
  - `tools/build_places.py` writes `provinces` (name, quest_region_id, regions), each region's `province` and `province_source`, and each landmark's `region` and `province` into `data/places_26161880.json`. It was rebuilt from the live client dump `logs/places_raw_latest.json`: 31/31 regions now have polygons, and 31/31 have a province.
  - `brain/places.py`:
    - every spot and region carries its province; answers carry `you_are_in_province`;
    - NPC answers put the copy in his province first and add a `summary` ("Zanik: copy in Brynmoor (your province) at Temple Woods, 143 m; other copies in …"), `spots_by_province` and `other_provinces`, keeping the spot list nearest first;
    - province names are answerable ("Fellhollow" → its regions, power levels, the lodestones and points he knows in it, and its nearest known point);
    - a wiki page that names a province narrows the spots to that province.
  - All of it is data-driven: no NPC names in code.
- **Search-before-building:**
  - Need: a province level above the map regions.
  - Searched: the reflection dump (AMapRegion, MapRegionIconComponent, enums, asset paths), the local wiki mirror, and the web (wiki region pages, third-party guides).
  - Decision: **adapt.** Use the game enum for names, the wiki for the mapping (names only), and the game tag when it reads hierarchical. There was nothing to reuse beyond the data itself.

## NIGHT SKIP WORKS: the bot summons a shelter and sleeps (verified 2026-10-25, 15:51 UTC, Luis via GFN)
- The game counted the bot as a player ("waiting for players to sleep … waiting on Claude").
- **Not enough:** the `bIsSpectator`/`bOnlySpectator` valve (the game still waited on Claude) and the PlayerRestComponent.IsSleeping flag alone.
- **Works:**
  1. SpawnActor of the Summon Shelter class `/Game/Gameplay/UtilityMagic/PerkSpells/SummonShelter/BP_Magic_SummonShelter.BP_Magic_SummonShelter_C` (class taken from a live shelter; the bot can't cast the spell itself) 3 m in front of the bot (`mod/experiments/shelter_spawn.lua`).
  2. `BedComponent:Sleep(puppet)` directly from about 3 m, with no walking (`mod/experiments/bed_direct.lua`). Walking to the shelter fails with path_blocked because of the shelter's collision.
  - `CanSleep(puppet)` returned false, but Sleep still took effect: CurrentRestingAreaActor = shelter, and the watcher showed bot `true|shelter` at 15:51:49.
- **Night passed at 15:51:52** (3 s later), and both woke at 15:51:55. Luis: "Worked a treat."
- Productise: the sleep skill's shelter fallback = spawn shelter + direct Sleep. The reflex fires when Luis's rest state goes sleeping. The spectator valve is useless and should be removed or relabelled.

## Gather: hit calibration, the damage cache, fallen logs (build 26161880, 2026-10-25 15:25-15:50 UTC, Luis watching)
Modules: `mod/experiments/reach_calib.lua` (teleport + rotate + one swing per grid point, no emulated damage), `mod/body/reach.lua` (shape window + aim solution), `mod/body/hitcheck.lua` (gate hooks + damage-cache hook). No crash (dumps stayed 10).
- **Damage cache hook works:** `RegisterHook("/Script/Dominion.PlayerMeleeAttackComponent:Multicast_SendDamageCacheData")` fires once per puppet swing with `TArray<FTimedDamageInfo>`. Read-only nested reads are fine (R15 is about pushing). Per swing: `TimeOffset` (0.597 s Chop, 0.917 s Overhead), `DamageInfo.Location` (the attacker; for the overhead Z is 40 cm lower = the shape Offset), `AttackId`, `Shape` = `DominionShape_Wedge`, `DamagedActors[]` -> `PointDamageEvent.{Amount, VictimLocation, HitLocation, InstigatorLocation}`. `victims=[]` = whiff.
  - **`PointDamageEvent.Amount` was 0.0 on EVERY recorded victim, including kebbit hits that did damage (coordinator), so it is NOT the applied damage.** Use the target's HP for damage, the cache only for contact.
  - `VictimLocation` is the victim ACTOR's origin. For a rolled log this is stale (below), which explains a victim 6.7 m from its hit point.
- **Chop (`BP_Player_Axe_Woodcut1`) on a standing ash (`BP_BM_Tree_Ash_03_C`, 24-point grid; d = 2D distance pawn to trunk origin, delta = pawn yaw minus bearing to the trunk):** hits for delta -75..+15 at d 110-140, -45..+45 at d 80; misses for +45/+75 at d >= 110; at d 170 only 2 of 6. So the target must lie about **35 deg to the RIGHT (clockwise) of the pawn's forward** = AngleOffset +35 with UE yaw sign; TopAngle 80 is the FULL width (+-40, widened by the trunk); reliable to **~140 cm from the trunk centre** (Depth 115 + trunk radius). The aim is `yaw = bearing - 35`.
- **Overhead (`Woodcut2`) on the same ash:** hits for delta -15..+15 at d 80-160, 0..+15 at d 200; -30 always missed. Straight ahead; Depth 170 + trunk radius, TopAngle 15 widened by the trunk at short range.
- **Fallen logs: the actor origin is STALE.** The trunk meshes are physics-simulated and roll, while `K2_GetActorLocation` stays where the piece spawned. `BP_Log_Oak_C_2147472221`: origin [96.08,1822.71] but `GetMidPointWorldLocation` [107.47,1820.60] (11 m away, log type 10 = a quarter piece). Every swing aimed at the origin, or at an axis computed from it, whiffed (18/18 around the bad point). Around the MIDPOINT: hits at 1.1-2.1 m facing it within +-15 deg (teleports closer were pushed out of the log's collision to >= 61 cm). **Aim logs at `GetMidPointWorldLocation`.**
- **Aimed contact still does 0 damage (tree gate).** 32 contacting Chop/Overhead swings on the ash (each logged ModifyDamage on DA_HatchetOnly plus a damage-cache victim) left it at 160/160 HP. Hook results on a verified contact (oak, 14:36): GetHeldEquipmentThatInflictedDamage -> HeldEquipment nil; IsDamageCausedByUnarmedAttack -> true; IsEquipmentOfSufficientTier/Category never called; ModifyDamage Amount 10; HP unchanged. Caveat: these out-param values were read in the single UE4SS callback, which ran after the inner functions (call order inner-first); if UE4SS called it before the body, they would be unset values. The "tier/category never called" part does not depend on that.
- **Whiffs in the gather loop also came from MOVEMENT:** swings issued while the AI MoveTo was still running pointed the wedge along the path (orient-to-movement). Gather now stops movement and waits 400 ms before each swing (`SETTLE_MS`).
- **Live gather results:** 15:02, the live handler: oak felled (2 emulated hits), stump chopped, 2 logs collected, then path_blocked. 15:15, hot-loaded (`gather_test`): **6 oak logs gathered end to end in 134 s** (14 emulated hits: 2 leftover splittable logs, 3 `BP_Log_Oak_C`, the old stump, 7 drops picked up). Bot inventory now 14 oak logs (persisted across the 15:32 restart).

## Summon Shelter ownership (2026-10-25, build 26161880), partial
- Luis reported "Claude's shelter has no owner" (bot shelter spawned via SpawnActor, see shelter_spawn).
- `BP_Magic_SummonShelter_C` super = `/Script/Dominion.UtilitySpell` (AUtilitySpell: GetCaster(), Dispel(), CastID, StartingDuration/EffectDuration). BP members: Bed (BedComponent), Interaction, Bedroll, tent meshes, VFX. Not in dumps/ (loads late); probe with experiments/shelter_probe.lua.
- Live probe (experiments/shelter_caster.lua): Luis's own cast shelter ALSO reports GetCaster/Owner/Instigator = nil and bed claimant "Unknown Character", claimed=false. So the caster is not exposed through reflection after the cast; the owner text the client shows comes from somewhere not yet found.
- `BedComponent:Claim(bot)` runs without error but `IsClaimedByPlayer(bot)` stays false (likely needs a PlayerController/PlayerState path the puppet lacks). Summoned shelters have bRequiresClaimingToSleepIn=false, so ownership does not block the night skip.
- Spawned shelters expire (the bot's was gone within ~10 min), consistent with UtilitySpell EffectDuration.
- Gotcha: debug_run loads modules from the DEPLOYED mod dir, so run tools/deploy_mod.ps1 after editing an experiment (no restart needed).

## Client jump lock after night skip (2026-10-25), unconfirmed cause
- After the bot-assisted sleep/night skip Luis could not jump; a relog fixed it. Possibly a client-side rest/sleep state not cleared. Watch for it on the next sleep test.
- **Productised (2026-10-25, `mod/body/sleep.lua`; needs a server restart to load):**
  - **Shelter fallback:** the class comes from `StaticFindObject` by path, then a live shelter's `GetClass()`, then `LoadAsset(path)`. It is spawned 3 m from the bot, on the side away from the nearest player, skipping spots within 5 m of a player or 4 m of another bed, at the bot's own height (no traces: R15). Then a direct `Sleep(puppet)`, never walking inside. `CanSleep` is logged but does not gate.
  - **Bed route:** walk to within 3 m, or sleep from up to 4.5 m when the bed's own collision stops the walk. Then a direct Sleep.
  - **Reflex:** fires on Luis's `PlayerRestComponent.IsSleeping` going true. On false it wakes the bot (`StopSleeping` only if the bot is still asleep; live, the game woke both), removes the bot's shelter (`SetLifeSpan(0.1)`, R6) and resumes follow.
  - The rest-flag and spectator options are removed from the service; `sleep_probe` keeps them, labelled ineffective.
  - UNVERIFIED: whether a spawned shelter outlives a server restart in the save (the bot removes its own on wake).

## Crafting: recipes, stations and unlocks from live game data (build 26161880, 2026-10-25, about 15:44-16:00 UTC, Luis connected; no crash, dumps stayed at 10, no restart)
Modules: `mod/scripts/recipe_dump.lua` (read-only extractor), `tools/build_recipes.py` -> `data/recipes_26161880.json` + `mod/body/recipe_data.lua`; service `mod/body/crafting.lua`; drift check `mod/experiments/craft_drift.lua` + `tools/craft_drift.py`. Each extraction stage ran alone with a ping and a crash-dump count after it.
- **Recipes:** `FindAllOf("RecipeData")` returns all **1232** loaded at idle (1225 `RecipeData` + 7 `URuneRecipeData`; 0 errors, 0.5 s game-thread CPU). Struct arrays (`ItemsConsumed` etc., `FItemDataContainer{ItemData, Count}`) read via `ForEach`/`get()`. Every recipe has `CraftTime` 0.5, `MaxCraftTime` 1.5, `CraftQuantityMultiplier` 1.2 (one has 1.0); `Min/MaxProcessingTime` mostly 8/12 s (14 at 120 s). `ChanceToProduceExtraItems` is 0.05 on 41 recipes, else 0. 52 recipes have an `AlternativeItemCreated` (burnt food) behind a player attribute (`ChanceToBurnFoodLevel2`). No recipe uses `FuelConsumedOverride` or `bConsumeItemsIndividually`. **There is no "tool required but not consumed" field on `URecipeData`** in this build.
- **Iron Bar** (cross-check with the wiki Bucket table): `RECIPE_Process_IronBar` = 3 `ITEM_Resources_IronOre` -> 1 `ITEM_Resources_IronBar`; `RECIPE_Process_Bar_Iron_From_Salvage` = 9 `ITEM_Resources_Salvage_Iron` -> 1 Iron Bar; both at the **Furnace** = `BP_Station_Smelter_C` (processing). Matches the wiki exactly. Whole-table check: 619 of 739 comparable recipes match the wiki; most of the 120 differences are wiki naming, about 20 are quantity changes (game data wins, e.g. Black platebody Mystic Cloth 2 vs wiki 4).
- **UE4SS: `FindAllOf` skips archetype objects.** The station component templates (`/Game/Gameplay/World/Stations/BP_Crafting_WeaponBench.BP_Crafting_WeaponBench_C:CraftingStation_GEN_VARIABLE`, 28 of them in the object dump) return 0 from `FindAllOf("CraftingStationComponent")` but resolve with `StaticFindObject(path)`. So `tools/build_recipes.py` takes the template paths from `dumps/<build>/UE4SS_ObjectDump.txt`.
- **UE4SS `UDataTable` Lua API works on the installed build** (`ForEachRow(fn(name, row))`, read-only): `DT_CraftingStationsDataTable` (12 rows), `DT_ProcessingStationDataTable` (25 rows, 8 of them developer test rows such as `TestOnlyFuel`), `DT_VendorDataTable` (5), and 24 `DT_Progression_*` tables with recipe unlock rows. `TArray<TSoftObjectPtr<URecipeData>>` (`LabeledRecipes[].Collection`) reads as paths via `GetObjectID():GetAssetPathName()`.
- **Stations** (row -> class -> display name): CraftingTable `BP_Crafting_StartingBench_C`, ToolsMeleeBench `BP_Crafting_ToolsMeleeWeapons_C` "Blacksmith's Bench", ArmourBench, FletchingBenchv2, JewelersBench, MysticForge, RuneAltar, PotteryWheel, RangeBronze `BP_Crafting_CookingBench_C` "Cooking Range", RangeStone, BrewingCauldron (crafting `BP_Crafting_Cauldron_C` and processing `BP_Station_Cauldron_C` share the row name); processing: Furnace `BP_Station_Smelter_C`, AdvancedSmelter "Blast Furnace", Kiln `BP_Station_CharcoalKiln_C`, Campfire, Grinder "Grindstone", Loom, Spinning Wheel, Sawmill, Stonecutter, Tannery, FermentationBarrel "Imbuing Barrel"; vendors: Fellhollow `BP_NPC_Death_C` "Death's Exchange", DowdunReach `BP_NPC_PostiePete_Dowdun_C`. `BP_Crafting_Cauldron_C`, `_Stone_Range_C` and `_CookingBench_C` are subclasses of `BP_Crafting_WeaponBench_C`, so the bot matches the exact class word, never `IsA`.
- **Processing data:** Furnace accepts Charcoal (`FuelValue` 120) and Fuel Pellet (360), `ProcessingRate` 5.0, 2 resource slots, 1 fuel slot, outputs spawn as `BP_RuntimeSpawnedWorldItem_ProcessingStation_C` (`bStoreOutput` false). Campfire burns logs/planks too (Oak 90, Maple 180, Yew 210).
- **Unlock rules** are `FProgressionBundleRow.UnlockQueryString`, e.g. Iron Bar: `ALL ITEMS[ Iron Ore ] AND ALL ACTORS[ BP_Station_Smelter_C ]` (`DT_Progression_Core`, row `T4_Resource_Bar_Iron`). 856 recipes have a bundle.
- **Luis's unlock mirror:** `PC.ProgressComponent.RecipesUnlocked` (TSet) read live: **827** recipes. Read-only, same pattern as `SpellsUnlocked`.
- **Interaction ranges:** `pawn.InteractableDetector.InteractionRanges` (TMap) = Short 250, Medium 350, Long 650, Fishing 1200 cm; every station's `Interaction` component is Medium. The bot counts as in reach within 350 + 100 cm (2D) and 300 cm vertically (the slack is UNVERIFIED).
- **The dev world has no placed station of any catalogued class** (FindAllOf on all 25 classes = 0), so no live craft has been run yet. Luis must build one (a Crafting Table is enough) for the live test and the drift check.
- Cost note: the `items` stage (all reads in one call) took 1.6 s of game-thread CPU; the others 0.02-0.9 s. Fine for a once-per-patch tool; run it when nobody is mid-fight.
- **UNVERIFIED models, to be measured by the drift check:** the multi-count craft time (`min(MaxCraftTime, CraftTime*1.2^(count-1))`), processing seconds (`count * mean(min,max) / ProcessingRate`, i.e. 2 s per Iron Bar) and fuel burn (`ceil(seconds / FuelValue)`).

### Recipe extraction and crafting emulation (search-before-building record, 2026-10-25)
- Need: a recipe/station catalog from game data, and server-side crafting for a bot with no PlayerController.
- Searched: Dragonwilds datamines and recipe exports; UE4SS DataTable / TSet / soft-pointer Lua docs; the wiki's Bucket API; prior art in the research doc (Mindcraft `getDetailedCraftingPlan`, mineflayer-crafting-util, Plan4MC).
- Found: no public Dragonwilds recipe dump with game ids (metabot.gg has a browsable item list only; guides are hand-written). UE4SS ships a `UDataTable` Lua API (`ForEachRow`, `FindRow`, `GetRowNames`; docs.ue4ss.com/dev/lua-api/classes/udatatable.html) and it is present in our UE4SS.dll. The wiki's `recipe` Bucket table returns all 1655 rows in one request (api.php?action=bucket).
- Decision: **adapt** `catalog.lua`/`build_catalog.py` (live extraction, staged, raw -> normalised, generated Lua table like `attack_data.lua`); **reuse** the UE4SS DataTable API and the wiki Bucket API for the cross-check; **build** the strict emulation (no existing server-side crafting emulation for UE4SS bots was found; the game's own `Server_CraftRecipe` needs a PlayerController inventory, R1/R8).
- Sources: https://docs.ue4ss.com/dev/lua-api/classes/udatatable.html · https://dragonwilds.runescape.wiki/w/Iron_Bar · https://dragonwilds.runescape.wiki/w/Furnace · https://dragonwilds.runescape.wiki/api.php?action=bucket · https://metabot.gg/dragonwilds/items

## Crafting: the real player path (build 26161880, 2026-10-25; from the reflection dump; a live capture is still pending)
Luis's direction change (binding, `docs/design/real-player-remediation.md`): no emulation. The emulated craft in `mod/body/crafting.lua` (take inputs from the Lua store, wait, grant outputs) was **removed the same day before it ever ran live**; `craft` answers `not_implemented`. What stays is route-independent: the recipe catalog and generator, the pure `plan`, the read-only feasibility check (`craft_check`), the station census and Luis's unlock mirror.
- **What a player's craft sends to the server** (all on `UInventoryController`, the PlayerController's component, Dominion.hpp:24740; reflected Server RPCs, so server-side `RegisterHook` sees them):
  - crafting station (bench, table, anvil, range, forge, vendor): opening the station is the generic interaction `PlayerInteractionManager:Server_RequestInteraction` (the station BP then runs `ToggleCraftingUIVisibility(PlayerCharacter)` → `ADominionPlayerController:Client_ToggleCraftingMenu(CraftingStationComponent)`); the craft itself is **`Server_CraftRecipe(UCraftingStationComponent* CraftingStation, URecipeData* Recipe, int32 Count, int32 BonusCount, float XPMultiplier, float BonusXPMultiplier, TArray<UInventoryComponent*> Inventories)`**. `Inventories` is the crafter's inventories plus linked storage (`UCraftingFunctionLibrary:GetLinkedInventories(WorldContext, BuildingPieceLocation, DefaultInventories, Out)`), so a craft can consume from nearby chests. The result comes back as `Client_OnCraftingResultHandler(ECraftingResult, Recipe, Count)`; `UInventoryController:CraftRecipe(...)` is the same call's client-side (non-RPC) entry, and `OnCraftingResult` the delegate.
  - `ECraftingResult`: Success 0, FailureMissingConsumedItems 1, FailureNotEnoughSpaceForCreatedItems 2, FailureCarryingTooMuchWeightForCreatedItems 3, FailureInvalidRecipe 4, FailureInvalidCount 5, FailureRecipeNotUnlocked 6, FailureNotEnoughVendorReputation 7. The game also checks bag space and carry weight, which `craft_check` does not (the Lua store has no capacity).
  - Pre-checks the game exposes (BlueprintCallable on `UCraftingFunctionLibrary`): `CanCraftRecipe(Crafter PC, CraftableRecipes, Recipe, Count, Inventories)`, `HasRequiredConsumedItemsForRecipe(Recipe, Count, Inventories, CraftingCostScale)`, `GetMaxAmountCraftableOfRecipe`, `IsValidRecipeForProcessing(Recipe, Inventories, FuelInventories)`. On the real-client route these replace our feasibility check.
  - processing station (Furnace, Kiln, Campfire, ...): no craft RPC. The player moves items into the station's `ResourcesInventory` / `FuelInventory` (`Server_MoveItemBetweenInventories(Src, SrcSlot, Dst, DstSlot)`, or `Server_SplitAndPutStack`, `Server_MoveAllItemsBetweenInventories`, `Server_FillStacksBetweenInventories`), starts it with **`Server_ToggleProcessing(UProcessingStationComponent*)`** (unless `bAutoStartProcess`), and the outputs spawn as `BP_RuntimeSpawnedWorldItem_ProcessingStation_C` world items at the station (`bStoreOutput` false for the Furnace), which he picks up through the normal magnet/pickup.
  - related: `Server_RepairItem(Station, Item, Recipe, Inventories)`, `Server_UpgradeMasterworkEquipment(Station, Inventory, SlotIndex, Inventories)`, `Server_SellItemFromInventory(..., CraftingStationComponent, Instigator)` (vendors).
- **UNVERIFIED until captured:** which of these a craft from Luis's GFN client actually fires, in what order, and with what params (e.g. BonusCount, XPMultiplier, the Inventories count). `mod/experiments/craft_drift.lua` now hooks all of the above (pre + post, params logged scalar-only) and `tools/craft_drift.py run` reports them as `real.rpcs` next to the inventory/station deltas. It has not run on a real craft yet: **the dev world has no station**.
- **Pawn yaw drifts during a swing toward `DesiredActionTarget` (16:00-16:05 UTC, gather_test).** Facing was exact right after `K2_SetActorRotation` + `SetControlRotation` (error 0), but `yaw_drift_deg` read at the damage point was -30..-112 deg on fallen logs (identical drift on consecutive swings from the same spot), and all 36 swings missed. Hypothesis (UNVERIFIED, last change before the stop): the melee attack turns the pawn toward `DesiredActionTarget`'s ACTOR ORIGIN, which is stale for a rolled log. Trees were fine because their origin is the trunk. Built but not yet run live: logs swing with no `DesiredActionTarget`. In reach_calib the hits on a log came with the pawn teleported and `DesiredActionTarget` set, so the drift must be measured there too before trusting the hypothesis.
- **Ground gatherables (read-only `interact_probe`, 15:58 UTC):** Luis's "sticks" are `BP_Spawner_AshBranch_0{1,2}_C` (`ABaseInteractableResource` <- `AGatherableResource`): `ItemData = ITEM_Resources_Wood_Ash` (display name "Ash Logs"), empty `ItemDropComponent.ItemsToDrop`, `IsResourceAvailable()` true, RespawnComponent 1/1, `InteractionComponent.InteractionPrompt` "Collect", InteractionType 0, InteractionDistance 1, `PlayerHookToTriggerWhenMadeUnavailableDueToInteraction` = `BP_FTUENotificationPlayerHook_C` (a player-only hook: a crash risk if fired for the puppet), foliage-depicted. Stones: `BP_Spawner_Stone_C`, `ITEM_Resources_Stone`, "Collect". Not interacted with: no grant route was tried (route-independent research only).
- **Generic perception works live:** `sense.look` (census via `InteractionComponent`, `DestructibleWorldActor`, `OreNode`, `DominionAICharacter`) listed the branch gatherables ("Ash Logs", verb gather), the summoned shelter ("Rest", interact), trees and logs (name from the class + drop item, verb chop from the gate tag), ranked "branches" to the four branch spawners (match 1.0).
- **Two-handed axe held one-handed:** the client anim proxy picks the pose from `LeftWeaponPoseType`/`RightWeaponPoseType` (`EAnimationPoseType` Unarmed/Default/Ranged) and `bIsLeftDefault`...; the axe's `UEquipmentData.Slot` = HeldTwoHanded and `HandPreference` = Left (catalog). Not fixed: we set only `HeldEquipmentActorRight`. `gather_probe held` now reads both hands, sockets, Slot and HandPreference, to compare with Luis holding a 2H tool (not yet run with him holding one).

## REAL CLIENT ROUTE (R2): headless client joins the dev server (2026-10-25, client build 26162923, server 26161880)
- **Headless works on this VM (no GPU):**
  - Launch: `steam.exe -applaunch 1374490 -nullrhi -nosound -unattended -nosplash -log` (tools/client_headless_test.ps1, which kills the client if free RAM falls below 600 MB).
  - The log shows `RHIAdapterName: Microsoft Basic Render Driver` and "This UE instance does not render". Steam SDK 1.57 and Redpoint EOS initialise, and it boots to `L_FrontEnd`.
  - Measured beside the server, with the bot puppet loaded on the server:
    - main menu: client about 1.0 GB, about 0.3 core;
    - **in world: client 1.86 GB, 1.2 cores**; server 0.93 GB, 0.2 core;
    - total CPU 64% of 4 vCPU, **1.2 GB RAM free of 8 GB**. Feasible but tight; 16 GB recommended.
- **Client-side storage:**
  - Characters are stored on the client: `%LOCALAPPDATA%\RSDragonwilds\Saved\SaveCharacters\<name>.json`, synced by Steam Cloud. Luis's were downloaded at login and backed up to `C:\GameServers\backups\luis_characters_20261025-173417`.
  - The client log is `%LOCALAPPDATA%\RSDragonwilds\Saved\Logs\RSDragonwilds.log` (UTC timestamps).
- **UE4SS on the client:** the same ASI-loader install as the server (tools/install_client_ue4ss.ps1). Mod `DWClient` (client_mod/) runs `client_io/cmd/*.lua` on the game thread and writes `client_io/out/*.json` (tools/client_cmd.sh).
- **Menu driven through the game's own UI API**, with no rendering or input needed:
  - `MainMenuUIAPI` (`FindFirstOf`) with `NavigateToScreen(EMainSubMenuType)` and `GetCurrentScreenType` / `GetCurrentScreenWidget`. Types: 2 Landing, 7 CharCreate, 8 CharSelect, 10 Worlds, 20 ConsentForm, 41 Eula.
  - **Character create (verified, `Claude.json` written):** `NavigateToScreen(7)`, then `OnCharacterTypeSelected_Standard()`, then `EditableTextCharacterName.EditableText:SetText(FText)` and `OnCharacterNameInputChanged(FText)`, then `CheckNameAndCreate()`.
  - **Consent:** `RefuseAll(<live WBP_GenericDialog3Buttons_C>)` (declines optional data sharing).
  - **EULA screen:** `OnConfirmClicked` / ConfirmButton `HandleButtonClicked` / the BndEvt fired but did not advance. Under NullRHI the ScrollBox has no layout (`GetScrollOffsetOfEnd` = 0). Bypassed by navigating directly; not needed for joining.
  - **Sign-in is required before joining:** Landing (2) `OnLoginTriggered()`, after which `DomMatchmakerSubsystem:IsUserLoggedIn()` is true. Without it the server rejects the connection with *"Missing user ID during connection"* (RedpointEOSNetworking).
  - **Direct panel:** `WBP_MainMenu_Worlds_C.DirectPanel` with `IpAddress.EditableText`, `PasswordText.PasswordText` and `GoToNextScreen()`. It only selected an "Online Session" list item and did not travel. Not solved yet.
- **JOIN VERIFIED:**
  - After sign-in, `KismetSystemLibrary:ExecuteConsoleCommand(pc, "open 127.0.0.1:7777?p=<base64 WorldPassword>?pf=PC?cpx=1")`. These are the same URL options a real client sends (seen in the server's `Login request` lines).
  - The client loads `L_World`. The server logs `Join succeeded`, then **`PlayerChar entered world [Account[PP:76561199797634942] Character Name[Claude] Guid[DCG:6CBB5130467171BAD741B5B4CD00286E]]`**.
  - So Claude is a genuine player: real login, real PlayerController, real character save.
- **Joined the Shockbyte world as Claude's own account (2026-10-25, 17:17 UTC).** bootymaxer (SteamID 76561198614193617) joined 203.16.163.204:20921 headless from this VM. The full client sequence is in client_mod/commands:
  1. `create_char` (first run only).
  2. `consent`.
  3. Sign in: `pick_char` → Landing (2), `CharacterSelectorWidget:OnSelectionUpdatedUpdatePlayerCharacter(0)` + `OnLoginTriggered()`.
  4. `join_server`: `open <addr>?p=<b64 pw>?pf=PC?cpx=1`, with the address and password in gitignored `client_io/secrets/server.txt`.
  5. `skip_intro`.
  6. The pawn spawns.
- **PlayerGuid = the Steam profile (persona) name** (`SetNameAndPlayerIdFromLocalUsername` → `Server_SetPlayerGuid [<persona>]`). Two accounts with the same persona collide: the server rejects the second with `Connection Failed for reason [DuplicateChar]`. bootymaxer had persona "luisdeburnaybastos"; it is now "Claude".
- **A new character plays the narrative intro first** (input mode `DIM_NarrativeIntro`, a Bink video that never ends under NullRHI). The pawn only spawns after it. `WBP_NarrativeIntro_C:OnOutAnimationFinished()` completes it, and the `BP_PlayerCharacter_C` pawn appears within seconds.
- Before the intro: `Remote Character load complete slot[Claude]` → `Started player profile stream` → `Connection to server has completed [success]`.
- **Client locomotion (Shockbyte, 17:22 UTC):**
  - The headless client has **no NavigationSystem** (`FindFirstOf("NavigationSystemV1")` = nil), so `AIBlueprintHelperLibrary:SimpleMoveToLocation(pc, goal)` does nothing.
  - **`pawn:AddMovementInput(dir, 1.0)` called every frame** (`LoopInGameThreadWithDelay(1, …)`) plus `pc:SetControlRotation` walked 13 m to 2.9 m in about 3 s. Luis confirmed he "ran towards me".
  - A 50 ms cadence leaves most frames without input, and the character jitters on the spot.
  - `pawn:Jump()` + `StopJumping()` jump visibly (Luis confirmed). `IsLocallyControlled()` = true.

## Client chat (R2): send and receive as a real player (2026-10-25, 17:30 UTC, client build 26162923, Shockbyte world)
Module `client_mod/scripts/chat.lua` (`M.start(log)`, `M.say(log, text)`); commands `chat_start`, `chat_say`, `chat_status`, `chat_probe` (read-only).
- **Live objects on the client (read-only probe):**
  - HUD `WBP_Chat_C` (`UChatWidget`), owned by `BP_DominionGameInstance_C` under `/Engine/Transient`. Its `OpenedChatSubWidget` is a `WBP_OpenedChat_C` with `MessageSendBox` (`UEditableText`) and `PlayerChatComponent` = Claude's own `BP_PlayerController_C.PlayerChat`. A second `OpenedChatSubWidget` under `/Game/UI/Chat/WBP_Chat.WBP_Chat_C:WidgetTree` is the class archetype: skip it (it has no MessageSendBox).
  - `HUDUISubsystem.ChatUIAPI` exists, but `UChatUIAPI` has no reflected functions.
- **SEND (VERIFIED, Luis saw "Claude: Claude here - chat test"):**
  1. `MessageSendBox:SetText(FText(text))`.
  2. Call `/Script/Dominion.OpenedChatSubWidget:OnTextCommitted(const FText& Text, ETextCommit CommitMethod=1 /*OnEnter*/)`, the native handler bound to the chat EditableText's commit (what Enter in the chat box runs).
  - Native code builds `FChatMessageData` from Claude's real identity and sends `Server_SendChatMessage`. **No struct is built in Lua.**
  - Afterwards the box text is "" (consumed).
  - It works with the chat box closed and invisible (`IsVisible` false, headless).
- **RECEIVE (VERIFIED):** post-hook on `/Script/JagexChatBackend.PlayerChatComponent:Client_ReceiveChatMessage(FChatMessageData)`. It fires on the client for every line, **including the sender's own line echoed back by the server** (about 1 s round trip, 17:30:39 send → 17:30:40 echo).
  - Read with `msg:get().MessageBody:ToString()`, `.SenderData.PlayerId` and `.SenderData.CharacterGuid` (an FGuid A..D). The nested struct reads in the hook are safe.
  - Luis's "hey claude" arrived as PlayerId 258, guid AD09D558…, and resolved to "Zezima". Claude is PlayerId 262, guid D06CFBE3….
  - `ChatWidget:OnChatMessageReceived` also fired once per line (counter `ui` = `rx` = 2), so the chat box displayed both.
- **Sender name:** GameState/PlayerState `DisplayNameComponent.SanitizedCharacterNames`, matched on `CharacterGuid.InnerGuid` → `CharacterName` (what the chat box shows). Fallbacks: PlayerState `OwnerGuid.CharacterGuid.InnerGuid`, then `PlayerId`.
- **`bIsChatEnabled` / `IsChatEnabled()` are FALSE on Claude's client, yet sending and receiving both work.**
  - `bIsChatEnabled` is a plain local `UPROPERTY` (not replicated, UHT).
  - `BP_PlayerController` gates the `IA_UI_OpenChat` input (opening the chat box) on `IsChatEnabled()`, so a human at this client couldn't open chat with Enter. The commit handler itself is not gated.
  - The platform check passed: the log shows `DominionContentRestrictionSubsystem: Updating privilege CanCommunicateOnline ... Succeeded`. Claude's `PlayerState.PrivilegeComponent:HasPrivilege(8 /*Chat*/)` = true.
  - Why it is false (headless HUD init?) is still open. It is **not** written by us.
- **Limits:** `Default__ChatDeveloperSettings.MessageCharacterLimit` (fallback 256). `say` clamps to it, strips control characters, and rate-limits below `SpamDetectionMessageLimit` per `SpamDetectionDuration`.
- **Events:** `client_io/events/chat.jsonl`, one JSON line each:
  - `{"type":"chat","from","text","ts" (unix s),"iso","self","player_id","guid"}`
  - also `chat_event` (`Client_ReceivePlayerEvent`, tag) and `chat_error` (`ChatWidget:OnChatErrorMessageReceived`).
- **Hot reload:** hooks are registered once (state in `_G.DWChat`) and dispatch to the newest handler, so re-running `chat_start` is idempotent (verified: second run registered nothing).
- **Search (search-before-building):**
  - Found no existing Dragonwilds or UE4SS chat mod using these classes. The closest is the Subnautica 2 MultiplayerChat UE4SS mod (nexusmods.com/subnautica2/mods/153), which uses its own RPC transport, so it doesn't apply.
  - UE4SS `FText()` docs: docs.ue4ss.com/lua-api/global-functions/ftext.html.
  - The wiki confirms public chat with a 256-character limit: dragonwilds.runescape.wiki/w/Chat.
  - Decision: **build a thin wrapper over the game's own UI handler**, reusing vendored dkjson (copied to `client_mod/scripts/dkjson.lua`).

## Client locomotion (R2) (2026-10-25, client build 26162923, dev server 26161880)
Service: `client_mod/scripts/move.lua` (go_to / follow / stop / status). Commands: `client_mod/commands/move_*.lua`. Nav oracle: `mod/experiments/nav_oracle.lua` (dev server, debug_run) plus `tools/nav_oracle.py serve` (file glue). Offline test: `lua client_mod/tests/test_move.lua <empty_dir>` (10 checks).
- **Dev-server nav oracle works:**
  - Call: `Default__NavigationSystemV1:FindPathToLocationSynchronously(<GameState>, a, b, nil, nil)`. It returns a `UNavigationPath`; `PathPoints:ForEach` gives the waypoints.
  - Example: creature to creature, 101.9 m, 7 points, 2-5 ms on the server. The full file round trip, client request to `resp.lua`, takes **about 157 ms**.
  - A failed path is still a valid object, with `GetPathLength()` = -1 and 0 points.
- **The dev server streams navmesh only around streaming sources:**
  - Settings: `wp.Runtime.EnableServerStreaming` = 1 and `...StreamingOut` = 1. The base navmesh is in `NavigationDataChunkActor`s, about 252 m cells. `RecastNavMesh-Default` has radius 30, height 150, RuntimeGeneration 2 (Dynamic).
  - With no player connected to the dev server, the chunks near Claude's Shockbyte spot were **0**, and every query failed.
  - **Fix:** an "anchor" `ATargetPoint` spawned there, plus `AddComponentByClass(/Script/Engine.WorldPartitionStreamingSourceComponent, false, <scalar FTransform table>, false)`.
  - Result: chunks went 0 → 1 → 4 within about 10 s, and paths resolve. No crash.
  - The anchor is relocated by destroy and respawn when a query starts more than 80 m away. The oracle answers `reason="loading", retry=true` for 6 s after a respawn, and the helper retries for up to 15 s.
- **Projection is required, and its out param fills a flat table:**
  - `K2_ProjectPointToNavigation(ctx, p, out, nil, nil, extent)` writes into `out.X/Y/Z` when `out` is a flat `{X,Y,Z}` table. `out.ProjectedLocation` stays nil, which is why the old body_probe never saw a projection.
  - Raw pawn capsule-centre points (about 0.8 m above the mesh) failed to path. Projected points work.
- **The start-area lodestone pad is a navmesh island** (as at Temple Woods). Paths from Claude's spawn spot come back `partial`, ending about 15-25 m out. The reverse direction, into the pad, is a 102 m path.
  - The mover follows a partial path to its end, then goes straight with the unstuck ladder.
- **Enhanced Input marshalling:**
  - `FInputActionValue` has **no reflected fields** (CXX dump: empty struct, size 0x20), so `InjectInputForAction` cannot be fed from Lua. The Nexus forum thread "how to call function with InputAction parameter" hit the same wall.
  - Use `EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction(action, {X=1,Y=0,Z=0}, {}, {})` (an IEnhancedInputSubsystemInterface function).
- **Sprint facts on Claude's client:**
  - `pawn.SprintComponent` (BP_Components_Sprint_C) has `SprintInputAction` = `/Game/Gameplay/Inputs/Actions/Basic/IA_Player_Sprint`, with `MinimumMovementInputRequired` 0.2.
  - `DominionUserSettings.bPressToSprint` = **true** (toggle).
  - `CharMoveComp` (DominionMovementComponent): `MaxWalkSpeed` 450, `GetSprintingMaxSpeed()` 680, `JumpZVelocity` 808.
  - `pawn.JumpMaxCount` = **2** (double jump available). `pawn.JumpInputAction` = IA_Player_Jump.
- **Steering verified on Shockbyte:** `go_to` (straight, no sprint) moved Claude 2.0 m in 0.6 s and stopped at a 1.4 m tolerance. That is 62 frames in 0.6 s, so the game-thread loop runs at about 100 Hz.
- **Time source:** use `GameplayStatics:GetRealTimeSeconds(pawn)`, not `os.clock()`. `os.clock()` is process CPU time, which runs faster than wall time on a multithreaded process (old walk_to.lua timeouts used it).
- **Client-side navmesh (later, needs a client restart):**
  - The client already streams `NavigationDataChunkActor`s (3 near Claude), but has no NavigationSystem or RecastNavMesh, and `NavigationSystemV1.bAllowClientSideNavigation` = false on the CDO.
  - Setting `[/Script/NavigationSystem.NavigationSystemV1] bAllowClientSideNavigation=True` in the client's Engine.ini might give a local navmesh from the same chunks, which would remove the dev-server dependency.
  - Untested.
- **Search (search-before-building):**
  - Nothing UE4SS-specific exists for client locomotion, Enhanced Input injection from Lua, or `FindPathToLocationSynchronously` from Lua. The UE forums confirm client-side FindPath returns empty PathPoints (answers.unrealengine.com/questions/102126, forums "Find Path to Location Synchronously returning wrong path on client").
  - Mineflayer-pathfinder (GoalFollow) and the Bloog bot (repath every update) were followed for the repath policy. Waypoint advance-by-one with a radius smaller than the waypoint spacing follows bugnet.io's "patrol waypoint skipping".
  - Epic docs: InjectInputForAction / InjectInputVectorForAction, the World Partition streaming-source component, and the World Partitioned Navigation Mesh guide (chunk actors stream with cells).
  - Decision: **adapt** (repath-on-goal-move from mineflayer and Bloog bot; server-side pathfinding with client steering, the usual UE pattern) and **build** the thin Lua loop and file glue. A `watchdog` file watcher was not needed for one polled file.
- **Follow test 1 (Shockbyte, 17:42:51-17:43:38, follow Zezima at 3 m):**
  - Sprint worked: 498-582 cm/s in the clear (walk 450), and 6.79 m/s in a later go_to.
  - The 45-66 cm/s "sprinting" windows were the stuck windows, not a sprint slowdown.
  - The stuck spot is an alcove under an overhang by the start-area lodestone, at (71.6, 1862.0, -34.7) m. Every oracle path from there was partial with length 0.06-1.9 m. Luis's breadcrumbs were 3.4 m above him. After the path ran out, straight-line steering went into the gap.
  - Luis: "he was following me correctly but there was an undercover, I ran out, he tried to get to me as the crow flies and got stuck in a gap."
- **Give-up bug (fixed):** per-window movement reset the stuck counter (jump/strafe wobble of about 52 cm, and 3-4 cm jitters), so a stuck go_to ran 110 s.
  - Progress is now **net displacement toward the goal ≥ 1.5 m, or a waypoint/crumb reached**, within 5 s (planning time excluded). Otherwise it stops with `{status:"failed", reason:"stuck", at_m}`.
- **Client hang (17:53:54, client PID 6400):** the GameThread sat in `NtWaitForSingleObject` under engine frames called from a UE4SS hook frame (export-only symbols). Render, async-loading and IO threads were idle. Stack: `logs/client/stack_6400_175704.txt`, taken with a non-invasive `cdb -pv`. Cause not identified.
- **IA_Player_Sprint:** ValueType Boolean (0), one trigger `InputTriggerDown`, `bConsumeInput` true.
- **Claude's measured jump envelope (live client, read-only):**
  - `JumpZVelocity` 807.9, `GravityScale` **1.85** (`GetGravityZ` -1813).
  - `GetMaxJumpHeight()` = `GetMaxJumpHeightWithJumpTime()` = **180 cm**; `JumpMaxHoldTime` 0.
  - `MaxStepHeight` 45, `WalkableFloorAngle` 45.5, `MinFallDamageHeight` 1500, `MaxFallDamageHeight` 2860, capsule half-height 88.
  - `SkillPerkComponent:IsPerkUnlocked(pawn.DoubleJumpSkillPerk)` = false. JumpMaxCount 2 does NOT mean double jump; that is Agility 10 (traversal research).
- **Physics traces from UE4SS Lua work (dev server, then the client):**
  - Call: `Default__KismetSystemLibrary:LineTraceSingle(ctx, a, b, 0 (TraceTypeQuery1), false, {}, 0, out, true, {R,G,B,A}, {R,G,B,A}, 0.0)` returns a bool.
  - An empty `out` table is filled as **nested** tables: `out.ImpactPoint.Z`, `out.ImpactNormal.Z`, `out.Distance`, `out.Time`.
  - Cost: about **1 ms per trace** from Lua on both (FHitResult marshalling).
  - **`out.bStartPenetrating` is unreliable.** It is a bitfield sharing byte 0xAD with `bBlockingHit` and reads true on clean floor hits. Use `Distance == 0` for "started inside geometry".
  - `CharacterMovement:K2_ComputeFloorDist(loc, 2000, 2000, 30, out)` also works on the dev server (`bWalkableFloor`, `FloorDist`, nested `HitResult`).
  - A trace started 5 m above the alcove spot begins inside rock, which confirms the overhang.
- **Local planner** (`client_mod/scripts/localplan.lua`; offline test `client_mod/tests/test_localplan.lua`):
  - A 1 m grid within 9 m of Claude. Two downward traces per cell (from feet + 1 m and from feet + 7 m) give up to two floor layers.
  - Edges: walk (≤ step), jump (≤ 1.65 m), drop (≤ 10 m). A* toward the far goal; an off-grid goal gives a segment to the closest reachable node.
  - Walls are checked lazily: horizontal traces on the chosen path only, re-planning on a blocked edge.
  - Patterns adapted: A* Pathfinding Project GridGraph/LayerGridGraph scan (arongranberg.com/astar docs), mineflayer-pathfinder move types, Lazy PRM (Bohlin & Kavraki 2000), Baritone-style segmented planning.
  - `move.lua` triggers it from a forward knee-height wall probe (hit normal Z < 0.7) or when stuck.
- **Nav oracle heartbeat:** `tools/nav_oracle.py serve` writes `client_io/nav/alive.lua` (`return <unix time>`) every second. The mover uses the oracle only while that is under 5 s old, so a stopped dev server costs nothing.
- **Windows file-lock race:** `os.replace(resp.tmp, resp.lua)` raises PermissionError while the client has resp.lua open, which crashed the helper once. Fixed by retrying.
- **Client locomotion v2: follow test 2, VISUALLY VERIFIED (Shockbyte, 18:11:53-18:13:11 UTC):**
  - Luis: *"He followed me quite well and jumped over obstacles."*
  - Luis ran about 200 m east at sprint speed. Claude held 35-40 m behind and closed to 3-4 m when Luis stopped.
  - 0 stuck events. 3 local plans from the wall probe, one with a jump edge, each about 0.9 s of standing.
  - 45 oracle requests. Sprint 6.6-6.8 m/s.
- **Planning standstill cut (v3):**
  - A world-aligned 1 m cell cache (30 s TTL) is shared by plans and by prefetch. Prefetch samples a cone 2-8 m ahead while moving, 2 traces every 3 frames, about 21 traces/s live (427 cells in 40 s). Budget is 16 traces/frame while standing.
  - Offline: a re-plan near an earlier one costs 0-50 traces (0.07-0.33 s), versus about 730.
- **"Walls everywhere" (18:18):**
  - Luis stood on a ledge 6.4 m up, out of jump reach. Inside the 9 m window, A* kept handing back routes to the cliff base, and the lazy wall check rejected each one, 12 re-plans in all.
  - Fixed: `localplan` now returns `unreachable_in_window` when its best node is under 2 cells closer than the start. Any planner failure, or the leader being more than jump + 1 m above within 15 m, switches to his breadcrumb trail from a crumb at Claude's level.
  - A dry run at the same spot toward Luis's next position found a 15-point walk route (737 traces, 1.04 s).
- **Persistent follow (v4, Luis's requirement):**
  - When Claude can still move but can't get closer for 5 s, follow enters `status="unreachable"`: he stands, faces the leader and re-checks every 1.5 s. He resumes when the leader moves more than 3 m, comes within jump reach, or comes near.
  - One event per episode goes to `client_io/events/move.jsonl`: `{"type":"unreachable","reason","leader_pos","my_pos","detail","mode"}`, then `reachable_again`.
  - Reasons: `leader_windstepped` (the leader's airborne rise exceeds 2.5 m; his airborne crumbs are dropped and the trail is cut at his take-off, so Claude holds there), `leader_double_jumped` (his `ReplicatedJumpCurrentCount` ≥ 2), `leader_above_jump_height`, `no_route`.
  - go_to still fails, with `reason="unreachable"` plus `why`.
  - The game's Unstuck is used only when Claude is wedged, meaning a 2.5 s backtrack test can't move him 50 cm.
- **The game's Unstuck path (found; not yet run live):**
  - `IA_UnstuckCharacter_Held`: Boolean, `InputTriggerHold` 3.0 s. It has no active mapping context in the world, so it is bound by the pause menu.
  - UI route: `MainMenuUIAPI:NavigateToScreen(12)` (`EMainSubMenuType` Pause = 12), then `WBP_PauseMenuScreen_C.ProgressButton_Unstuck:HandleHeldActionCompleted()` (UDomHeldProgressBarButton), then `Resume()`.
  - Server side: `ADominionPlayerController::Server_TeleportToPlayerStart` (not called directly, per the R2 rule).
- **The lodestone pad is a navmesh island in every direction** on the dev navmesh. From the alcove (71.6, 1862.0, -34.7), the path west into the pad is complete (12.8 m). Paths east, north-east and west out of the pad are all partial: 0.12 m, 13.1 m and 24.0 m to the boundary.
- **Auto-generated nav links (UE 5.5 experimental) exist in this build:**
  - `ARecastNavMesh.bGenerateNavLinks` is false by default.
  - `NavLinkJumpDownConfig` defaults: bEnabled, JumpLength 150, JumpDistanceFromEdge 10, **JumpMaxDepth 150**, JumpHeight 50, JumpEndsHeightTolerance 80, SamplingSeparationFactor 1, FilterDistanceThreshold 80, LinkBuilderFlags 1, **Up = Down area class = NavArea_Default**. So links are bidirectional, and the 1.5 m depth is within Claude's 1.65 m jump.
  - Links are generated during tile generation (dev.epicgames.com "automatic-navigation-link-generation"). Experiment: dev-server ini `[/Script/NavigationSystem.RecastNavMesh] bGenerateNavLinks=True`, then a restart (results below).
- **Auto nav links, RESULT (dev server restarted 18:2x UTC with the ini; bGenerateNavLinks reads True):**
  - The cooked chunk tiles carry no links: after the restart, the pad and alcove paths were identical to the baseline.
  - **Dirtying the local tile columns** regenerates them with links. Method: a movable `StaticMeshActor` with `/Engine/BasicShapes/Cube`, scaled flat (60-160 m), spawned 30 m ABOVE the area so it obstructs nothing on the ground, then destroyed after 3 s. `IsNavigationBeingBuilt` reads true for a few seconds.
  - The pad → east query then went from 3 points / 18.96 m (ending at pad level) to **8 points / 27.06 m, with a +1.85 m rise over 1.5 m (an up-link) onto the upper level** where Luis stands. That is the jump players use to leave the pad.
  - The 3.4 m alcove ledge stays unlinked (JumpMaxDepth 1.5 m), which is correct for Claude's 1.8 m apex.
  - `nav_oracle.lua` now does the rebuild automatically, once per anchor placement after it has settled (`links_rebuilt: true` in the reply).
  - `move.lua` v5 marks oracle segments rising more than 60 cm over less than 3 m as link endpoints. It walks to the take-off point and jumps there; link endpoints need strict 3D arrival, while ordinary points get a slope-aware tolerance of 65 cm + 0.9 × horizontal distance.
- **World-teardown crash rule (client, 18:08:42 UTC):** an access violation came from a Lua UFunction call in a game-thread loop 2 s after `disconnect.lua`. My `move_plandry.lua` LineTraceSingle loop had started 2 s earlier in the same batch, a likely source.
  - Convention: `_G.DW_PAUSE = true` is set by disconnect/join and cleared by the bridge 3 s after a new pawn is stable.
  - `move.lua` (loop, prefetch, traces, planner, Unstuck callback) and `move_plandry.lua` make no engine calls while it is set, or while the controller/pawn is invalid. Any per-frame Lua loop must do the same.
- **Slopes vs steps in the local planner (18:34):**
  - Cells 1 m apart on a walkable slope (up to 45.5°) differ by more than the 45 cm step. Before, they became jump edges, so Claude jumped up a 30° ramp five times.
  - Now |dz| ≤ 0.9 × run is a provisional walk. The lazy check takes ONE downward trace at the edge midpoint: a profile within 30 % of linear is a slope; otherwise it is a step, and that edge is re-planned as a jump/drop.
  - Offline: the 30° ramp is walked and a 90 cm step is jumped (`test_localplan.lua`, 13 checks).
- **Self-collision of traces (19:22 live root cause):**
  - `bIgnoreSelf` ignores Claude's pawn but NOT his attached gear actors (platebody, cowl, axe), which block traces. Every lazy wall check leaving his own cell hit his gear ("walls everywhere" / verify_exhausted), and so did the forward probe that started at his centre (constant "wall_ahead").
  - Fixes: the probe starts 60 cm out; wall checks are clipped within 55 cm of him (80 cm hid real walls next to him and caused corner cutting); his own cell uses his feet height.
- **Traces now use the pawn capsule's own collision profile:** `LineTraceSingleByProfile(ctx, a, b, FName("Player"), ...)`. `CapsuleComponent:GetCollisionProfileName()` = "Player". It is identical to Visibility at the spot tested, but it is the right semantics.
- **Ramp over dead space:** two surfaces less than head clearance apart are one walkable surface, the UPPER one (the lower has no headroom). Before, the ground under a ramp won and the ramp was dropped.
- **Oracle projection:** ±1.5 m vertical first, then ±6 m. With ±6 m a start under the church floor snapped onto the floor above it. Afterwards the pit → Luis (57.6, 1880.6) path was complete (26.6 m).
- **Lazy-check refinements:**
  - the first segment is checked from Claude's real position, not the cell centre (it can clip corners);
  - a wall hit point blocks every nearby crossing edge (one hit, not one re-plan per edge);
  - the local waypoint arrival radius is 45 cm (70 cm cut corners).
- **Oracle as primary router (19:44 live):** a 20 m cliff at (440, 1820, -37) below the grave plateau (441.6, 1829.1, -16.7) saw nav_requests = 1. The local planner suppressed oracle requests and fought the cliff toward the final goal.
  - Now: goals beyond 10 m (or above jump height) always get oracle routes; the oracle is re-queried after every local-plan failure; the local planner aims at the oracle route's next waypoint.
- **Corridor streaming (dev oracle):** trips over 120 m spawn streaming-source anchors every 120 m to the goal (at most 5), answering "loading" while they settle (10 s; the helper retries for up to 25 s). The goal area also gets its link rebuild.
  - Start area (100, 1830, -30.7) → grave area (442.6, 1836.5, -15.6): **complete 346.6 m, 13-point path**.
  - The 19:22/19:39 "357 m no_path" was really the START: the church pit is a navmesh island, so every path from it is partial.
- **Church start pit (Luis):** "a ramp in the middle to exit; he goes round the side of it, under the floor". Under-floor feet level is about -35.5 m and the church floor -32.1 m. The dev navmesh connects pit → ramp → upper floor only via an auto-link (73.9, 1874.0, -33.95) → (74.26, 1875.46, -32.1), and the upper floor does not connect to the doorway (89.5, 1851.2, -31.4).
  - The trap is seeded as **provisional** in `data/nav/L_World_seeds.json` (with a taboo toward the alcove), pending a recorded demo walk.
- **Lesson (19:41):** Claude got out of the pit by FOLLOWING Luis's breadcrumbs where go_to failed. But the trail was lost when the next command reset the move. Trails are now flushed to memory whenever a move ends or is interrupted.
- **Human-proven hill route:** Claude's own trail while following Luis up the grassy hill to the grave plateau (19:45), 27 points, route `grave_hill_up` in the seeds.
- **Navigation memory (`client_mod/scripts/navmem.lua`, tests `test_navmem.lua` 21/21, integration scenarios in `test_move.lua` 46/46):**
  - Per-world routes (self trips; the leader's walked trail as `demo:<name>`) in `data/skills/<world>/nav_memory.json`, plus map seeds. Dijkstra over route points, join edges (4 m), learned links as one-way edges, and taboo penalties (×10).
  - Traps: inside one with the goal outside, its exit comes first. A stuck spot that is later left by 15 m becomes a learned trap whose exit keeps growing for 10 more metres. Teleports (a jump of more than 10 m between samples) and candidates over 10 min old are discarded. The failed direction is tabooed.
  - `move.escape_trap()` / `commands/move_escape.lua` is for respawn/rejoin.
- **Escape ladder (v10):** memory route → learned link → **Bug2 wall-following** (left-hand, then right-hand, 12 s / 35 m per side, probes every 3rd frame) → (wedged: the game's Unstuck) → unreachable.
  - With a player within 40 m: one `{"type":"stuck","ask":"lead_me","where","helper"}` event. A go_to then waits (`waiting_for_lead`, up to 60 s), follows the helper's trail out, and carries on to its goal (`led_out`).
- **Leader double-jump detection:** use CHANGES of `ReplicatedJumpCurrentCount` (the replicated value stays stale after landing; traversal agent).
- **Church respawn → doorway, learned live (20:21 UTC):** a go_to to Zezima from the respawn point (50.7, 1890.2, -35.9) arrived in 18 s via the local planner, then Luis's breadcrumbs.
  - Stored as a self route: 23 points along the church floor, then UP THE CENTRAL RAMP (points 8-12 rise 3.7 m over ~10 m, about 20°), then to the doorway (88.55, 1850.9, -32.25).
  - Now verified map seeds: trap `church_respawn` (10 m, exit = that route) and trap `church_start_underfloor` (pit → ramp base by a 16 m dev-oracle leg, then the ramp).
  - The bridge calls `escape_trap()` after every respawn and rejoin.
- **New character (Agility 99, 2026-10-25 ~20:19 UTC):** `IsPerkUnlocked(DoubleJumpSkillPerk)` = true. Single jump unchanged (apex 180 cm, GravityScale 1.85).
  - Double-jump EDGES are disabled until measured by `client_mod/commands/move_calib.lua`, which writes `data/envelopes/Claude.json`; move.lua prefers it.
  - The calibration checks the spot (flat ±30 cm within 1.5 m, open at knee and head 2.5 m round, no roof) and takes the pawn via the arbiter.
- **The leader proxy reads (0,0,0) while relevancy-culled or teleporting (20:25 live):** Claude "followed" to the world origin 1.8 km away.
  - An origin position now counts as not visible. A target jump of more than 50 m resets the route and trail.
  - A leader more than 300 m away means hold plus `{unreachable, reason:"leader_far"}` (the lodestone catch-up hook).
- **Luis's double jumps rise 2.6-3 m** and were misread as Windstep at 2.5 m, which cut his trail. Windstep is now only rises over 4.5 m.
- **Low obstacles (felled log, 20:30 live):** the forward probe checks at knee and at jump height minus 30 cm. Blocked low but clear high means jump at ≤ 1.2 m with no planning. The lazy wall check marks such edges as hop edges (jumps), not walls.
- **Water (20:30 live: "he went straight through the lake"):**
  - This build has no UE Water-plugin bodies and no water PhysicsVolumes client-side.
  - The game signal is `pawn.EnvironmentComponent:GetNormalizedWaterDepth()` (0 when dry; above 0.25 = wading) and `CharacterMovement.MovementMode` 4 (swimming).
  - Water cells (2 m) are learned and persisted per world in navmem. On the first wade, a "water sense" calibration tests which trace channel (Visibility/Camera/WorldStatic/WorldDynamic) sees the surface above the bed (the pawn profile passes through water). If one does, the planner samples water in its window.
  - Water cells cost ×8; segment targets prefer dry ground; known water ahead triggers a re-plan.
  - UNVERIFIED live: whether any channel sees the real water surface.
- **Wall-point blocking fix:** a recorded wall hit blocks an edge only if it lies ahead along the edge (projection 0.1-1). A hit at the start cell had blocked every edge leaving it.
- **Trace profile bug (2026-10-25 21:33+, fixed 23:09):** Claude's capsule reports `GetCollisionProfileName()` = **"Custom"** (per-channel responses). "Custom" is a label, not a preset, so `LineTraceSingleByProfile(..., "Custom")` logs `COLLISION PROFILE [Custom] is not found` and returns NO hit: 27k log lines, a blind local planner.
  - Now: try the game's preset **"Player"**, then the engine's "Pawn", each validated by one downward trace beside Claude against the Visibility floor. Otherwise use the Visibility channel. The choice is shared in `_G.DW_TRACE_PROFILE` and shown as `status().trace_profile`.
  - Live on the dev world (23:14-23:15): "Player" validated; 0 profile errors; a 15.9 m go_to with 775 traces arrived in 6.3 s.
  - The offline fake had ignored profile names, which hid the bug. It now rejects unknown names like the engine (regression scenario 20).
- **Main menu pawn:** in `L_FrontEnd` the controller owns a `DefaultPawn` at (0,0,0). A go_to issued during a relaunch "drove" it. move.lua now requires a pawn with CharacterMovement: start() refuses, and ticks pause.
- **Client hang L28 (2026-10-26 07:14:32 UTC):** the cdb stack (`logs/client/hang_7368_20261026_081432.txt`, UTF-16) has the GameThread in `NtReadFile` ← `ucrtbase!fgetc` ← UE4SS Lua. That is the DWClient runner's `io.popen('dir /b ...')` pipe read, every 2 s.
  - Fixed: the runner reads `client_io/cmd/queue.txt` from a saved offset (writers append the name after writing `<name>.lua`). No process is spawned on any poll; module mkdirs go through a probe-and-cache `ensure_dir`.
  - Live (07:39:54): `DWClient loaded (json=dkjson, runner=queue)`; client_cmd and watchdog probes round-trip; bridge OK.
  - Design: `docs/design/client-runner-queue.md`. Test: `client_mod/tests/test_runner.lua`.
- **Deployment gotcha:** the game loads DWClient's `main.lua` from the DEPLOYED copy (`C:/Program Files (x86)/Steam/steamapps/common/RSDragonwilds/RSDragonwilds/Binaries/Win64/ue4ss/Mods/DWClient/scripts/main.lua`, installed by `tools/install_client_ue4ss.ps1`), not from the repo. Every other client module is `loadfile`d from the repo by path. A `main.lua` change must be copied there, then the client restarted.
- **The game's Unstuck crashed the client (20:49:34 UTC):** move.lua requested it twice via the pause menu (20:49:25 and 20:49:33) while Claude was on top of the shelter.
  - Crash: an access violation in UE4SS `LuaType::push_arrayproperty` (a Lua loop reading a TArray on an object being replaced after the teleport). Same class as the 18:08 disconnect crash. Dump `ue4ss\crash_2026_10_25_21_49_34.5457439.dmp`, stack `logs/client/hang_unstuck_8712.txt`.
  - Unstuck is now DISABLED by default (opt-in per call only; if used, it holds `_G.DW_PAUSE` across the teleport).
  - A wedged Claude reports `{stuck, ask:"lead_me", reason:"wedged"}` instead: a follow waits "unreachable"; a go_to waits for a lead.
  - A perched Claude (floor more than 60 cm below his feet at 3 of 4 points 90 cm round) first steps off: a jump forward, then 8 short pushes.
- **Two reach failures from Director run 3 (2026-10-26, 16:05-16:09 UTC, diagnosed from `logs/client/client.log`):**
  - **Sticks on a ledge.** `BP_Spawner_AshBranch_01_C` pickups sat at z ≈ -3160 while Claude stood about 4 m lower (capsule -3496). Every local plan saw floors at about -3216 with walls on top ("walls everywhere", djump edges).
    - Cause: gather's `stand_point` sent the goal at Claude's OWN height (`Z = me.Z`). So move planned a level walk, its dz0-based reason could never be `target_above_jump_height`, and gather's 40 s approach timeout ended each try as a bare "timeout".
    - Fix: the goal takes the target's height when it differs by more than 1.5 m. Targets far off his level sort later, and a 2D "close" from under a ledge no longer counts. The failure uses move's progress why (a timeout's stall why now names the height), in words: "they're higher up than I can jump".
  - **Pond.** A `BP_WaterVolume_C`'s origin is about 3.1 m under the surface (cam surface -3171, origin -3495). Interact's 6 spots round the origin were all in the water, and every one ended too_far.
    - Fix: `move.shore_point(log, water_m)` traces the water's edge (the water channel against the Player profile floor, or navmem water cells): the bank point to stand on, plus the surface point to face, and alternatives along the bank.
    - skills.new_episode uses it for water volumes (the bank counts as not "on top").
    - move also no longer swaps a goal that is IN known water for nearby dry ground.
- **World id (2026-10-26):** one resolver, `mod/body/util.lua` `U.world_id(root, opts)`. The order is: explicit (`opts.world`, `_G` or env `DW_WORLD_GUID`, `client_io/world_guid.txt`), then the joined server (`logs/state/last_join.json` addr against the FIRST line of `client_io/secrets/server*.txt`; the password line is never read), then `server_<host>_<port>`, else "unknown".
  - traverse_learn and move's nav memory use it; before, they fell back to "shockbyte", so dev learning was filed there. Note: `data/skills/shockbyte/nav_memory.json` holds dev-world routes learned before this fix.
- **One approach-progress watchdog (2026-10-26, offline):**
  - Every go_to/follow fills `move.status().progress` = {verdict ok|stalled|unreachable, why, dist_m, best_dist_m, since_s, elapsed_s, target_moved_m}.
  - It is set through `opts.progress` = {stall_s=12, gain_m=0.5, budget_s, moving_m=3, to={x,y,z}}; `move.progress_reset(log[, opts])` restarts the window.
  - The whys are move's own reasons, plus cant_catch, too_long, blocked, no_progress and target_not_visible.
  - `move.why_words(why, thing)` is the one words table, with grammar for "you", "it" or a name. It replaces the separate stall timers and word tables in combat, skills and shoot.
  - It only reports; move never stops on its own verdict. Tests: test_move scenarios 37-44.
- **Avoid zones for combat hazards (2026-10-26, OFFLINE ONLY, not yet live; spec `docs/design/velgar.md` §3c):**
  - Files: `client_mod/scripts/avoidzones.lua` (pure geometry), the move.lua API `set_avoid_zones` / `escape_zones` / `status().avoid`, and `localplan.lua` (`cell_cost(x, y, floor_z)` plus `dry_slack`).
  - Tests: `client_mod/tests/test_avoidzones.lua` and `test_move.lua` scenarios 25-36. Live-check commands: `move_zonetest`, `move_zoneescape`, `move_zoneclear`.
  - **Units:** zone x/y/z are in metres, like every move API; `r_cm` is in cm; `until_s` uses the same clock as move and combat (`GameplayStatics:GetRealTimeSeconds`), or `ttl_s` is relative.
  - **Normalisation:**
    - scalars only (UE4SS R15), so a table field is refused;
    - |x| or |y| over 50 km is refused as "looks like centimetres";
    - the version (which triggers a re-plan) changes only when the geometry changes, so re-sending every frame is free.
  - **Design (adapt, not build):** zones are a planner cell COST, not walls (influence-map A*).
    - The cost is 20 cells, plus 2 per second still left, capped at 60. So with no other way, the route crosses the zone that ends soonest, and `status().avoid.crossing` and the log say so.
    - The local planner aims at a zone-free cell up to 6 m further from the goal.
    - A follow whose leader stands in a zone holds at its edge (`status = "near_zone"`); a follow standing in one steps out first.
    - Navmem/oracle routes are not zone-aware: zones are short-lived and local, so the 9 m local planner handles them as Claude approaches.
  - **`escape_zones`** is an EQS-like query:
    - Candidates: 32 rays, taking the first point on each outside every zone (+40 cm capsule, +60 cm), filtered by the bound and sorted nearest first.
    - Reachability, using real traces (at most 8 candidates): a knee-height wall trace, plus floor traces every 1.5 m (no drop over 2.5 m, no climb, no start inside geometry); known water is skipped.
    - eta = 0.25 s + distance / speed, where speed is the measured sprint (else 6.8 m/s) or MaxWalkSpeed. If eta > time_s, it answers `too_slow` and does NOT move.
    - Otherwise it does a sprint-forced go_to, which arrives as soon as Claude is out of every zone (`result.out_of_zones`). The reply carries `prev` (the snapshot) so the arbiter can `restore` afterwards.
  - **Search record:**
    - Critch & Churchill, influence-map A* (https://www.cs.mun.ca/~dchurchill/publications/pdf/cog2021sneak.pdf);
    - danger zones as a path cost (https://discussions.unity.com/t/how-to-create-temporary-danger-zones-on-ground-and-have-ai-characters-move-from-them/666329);
    - Unreal area-cost pitfalls (https://forums.unrealengine.com/t/making-unreal-ignore-certain-areas-when-pathfinding/412637);
    - Limited-Damage A* (damage as a feasibility budget, not adopted: a soft cost is enough here; https://avesis.metu.edu.tr/yayin/12fd2447-c287-40f0-bbf3-b62962cb2796/limited-damage-a-a-path-search-algorithm-that-considers-damage-as-a-feasibility-criterion).
    - The engine-side alternatives were not usable: a NavArea/NavModifier cost would need the server's navmesh, and the client has no navmesh (route R2); EQS needs a server AIController. A search for Unreal EQS "nearest safe point" returned only Unity NavMeshQueryFilter docs.

## Client perception + inventory (R2) (2026-10-25, 17:30-18:00 UTC, client build 26162923, Shockbyte world)
Modules: `client_mod/scripts/sense.lua` (census + me), `client_mod/scripts/inventory.lua` (list, collect, equip, unequip, drop). Commands: `client_mod/commands/sense_*.lua`, `inv_*.lua`. Both reuse the dependency-free `mod/body/util.lua` via `loadfile` (works unchanged on the client).
- **Search (search-before-building):** no Dragonwilds or UE4SS mod drives inventory/hotbar/interaction from Lua (Nexus Dragonwilds list has only storage-slot mods; a Gothic 1 Remake UE4SS mod uses items from inventory, other game). UE4SS docs: `FindAllOf` returns nil or a table; a UFunction found by `StaticFindObject` is called as `fn(context, ...)` (docs.ue4ss.com/lua-api/classes/ufunction.html). Epic docs: `InjectInputForAction` / `InjectInputVectorForAction` "run modifiers and triggers as if the input came through the input system" (dev.epicgames.com .../IEnhancedInputSubsystemInterface/InjectInputForAction). Nothing found on calling interface functions from UE4SS. Decision: **build** thin wrappers over the game's own UI handlers and input actions (the MainMenuUIAPI pattern already proven on the menus).
- **Perception (read-only, verified):** on Claude's client `FindAllOf` returns only replicated (net-relevant) actors.
  - Players: `DominionPlayerCharacter` minus the local pawn. Luis's pawn appears only within relevancy range (it was absent at 300 m and present at 8 m); **PlayerStates are always present** (`players_online` = Claude, Zezima).
  - Creatures: `DominionAICharacter.LoadedData` (`UAIDataAsset`): `AIName` (FText: "Magpie", "Kebbit"), `Archetype` (`AI_ARCHETYPE`: 0 Aggressive, 1 Defensive, 2 Passive, 3 Bird, 4 NeutralUntilAttacked; Kebbit = 4, Magpie = 3), `bIsBoss`, `GameplayTags`; `CurrentAlertnessState` (`EAlertnessState`, 4 = COMBAT); `PowerLevel`. Health `HealthComponent:GetAuthoritativeHealth()`; **`HealthComponent.MaxHealth` is 0 on players and some AI, use `GetMaxHealth()`** (Kebbit 78/78, Magpie 2/2, Zezima 250/250). `GetAttitude` (DominionAiFunctionLibrary) was not called on the client (it may need the AI controller, which clients lack).
  - World items: `WorldItem` -> `ItemData.Name`, `GetStackSize()`. **Items a player drops have `MagneticComponentGrantItem.bAutoMagnetizationEnabled = false`** (`bAllowAutoMagnetization` true, category 1): the magnet never pulls them; Luis's drops lay 2.6-3.4 m from Claude (MagnetRange 350) untouched. They must be collected with interact ("Collect").
  - Resources: `DestructibleWorldActor` / `OreNode` / `BaseInteractableResource`. Tool gate from `DamageModifiersWhenTree` (trees) or `DamageComponent.DamageModifiers`: `RequiredCategory.TagName` + `RequiredTier` (Stone Boulder Pickaxe tier 1 HP 75; Ash splittable log Hatchet tier 1 HP 80; Ash Sapling HP 25, prompt "Uproot"). Names: `AWorldActor.DisplayName` / `StumpDisplayName`. Standing trees are foliage ISM on the client too (none listed at the spawn); `sense` does not convert foliage (state change).
  - Interactables: owners of `InteractionComponent` (prompt `InteractionPrompt`), typed by actor family (`WorldChest`, `WorldLodestone`) then component family (`CraftingStation`, `ProcessingStation`, `EnchantingStation`, `RestingArea` = bed, `Lodestone`, `Container`, `Inventory` = storage). Seen: Wise Old Man ("Talk"), Lodestone ("Teleport", `BP_WorldLodestone_C`), Lore Item ("Read"), loot chests ("Open"), Rememberance Shrine.
  - Census cost: 50-90 ms on the game thread at 40-300 m.
  - Me: `pawn.StaminaComponent:GetStamina()/GetMaxStamina()/IsExhausted()` (100/100); `pc.SkillComponent.Skills` (`TArray<FSkill{CurrentXP, SkillData}>`, `SkillData.Name`) + `SkillComponent:GetSkillLevel(SkillData)` + `GetTotalSkillLevel()`: 12 skills at level 1, total 12.
- **Inventory layout (verified):** `pc.InventoryComponent` = `BP_Components_Inventory_C` (`UPagedInventoryWithLogComponent`), 176 raw `ItemSlots`: raw 0-7 = hotbar (`NumberOfQuickActionSlots` 8), then `InventoryPages` in order: InventoryItems 32 (raw 8-39), InventoryRunes 32, InventoryAmmunition 32, InventoryQuestItems 72. The UI's `(SlotType, SlotNum)` = `EInventorySlotType` (0 QuickAction, 1 Items, 2 Runes, 3 Ammo, 4 Quest, 5 Loadout) + index within the page. `pc.LoadoutComponent` = 12 slots in `ELoadoutSlot` order. Fresh character: Torch (hotbar 1), Adventurer's Tunic + Leggings worn.
- **Live UI objects on the client:** `InventoryUIAPI` (in `HUDUISubsystem`, its `PlayerController` = the local PC; `GetInventorySlots(t)` returns a Lua table: 8/32/32/32/72); the hotbar widget `WBP_Inventory_QuickAccesBar_C` under `/Engine/Transient...WBP_Inventory_MainPanel_C` (the other instance is the widget-tree archetype) whose `QuickAccessSlotInputActions` = `IA_Inventory_QuickAccess_SelectSlot1..8`, context `IMC_GameplayUI`.
- **Collect = the interact key (verified, 7 items):** `pawn` InteractableDetector (`BP_Components_InteractionDetector`) picks `CurrentInteractable` itself (DetectionRange 900, CharacterTraceDistance 600). One frame of `StaticFindObject("/Script/EnhancedInput.EnhancedInputSubsystemInterface:InjectInputVectorForAction")(EnhancedInputLocalPlayerSubsystem, IA_Interact, {X=1,Y=0,Z=0}, {}, {})` (IA from `PlayerInteractionManager.InteractAction`) collected the targeted item; the detector then moved to the next one. Shield, pickaxe, axe, platebody, dagger in 5 presses; the cowl 3.4 m away was not targeted until the locomotion agent stepped him to 1.4 m facing it. Items landed in the first free hotbar slots (equipment) with **Luis's own instances** (durability kept: Bronze Shield 982/1050, Mithril Pickaxe 2124/2400, Mithril Logging Axe 2240/2400, Bronze Platebody 870/1250). No crash; interface UFunction called on the implementing subsystem works.
- **Equip = the hotbar number key (verified):** `WBP_Inventory_QuickAccesBar_C:UseItemInSlot(i)` (0-based):
  - Mithril Logging Axe (slot 3, key 4): Loadout HeldRight (7) **and** HeldLeft (8) both = the axe (two-handed); pawn `PlayerEquipmentComponent:GetHeldEquipmentDataLeft()` = `ITEM_Logging_Axe_Mithril`, `HeldEquipmentActorLeft` = `BP_Logging_Axe_Mithril_C`, `GetHeldEquipmentDataRight()` nil. The axe stays listed in its hotbar slot (the loadout references it).
  - Bronze Platebody (key 5): Loadout Body = platebody, the worn Adventurer's Tunic moved into that hotbar slot (the game's swap); pawn `CurrentBodyWearable` = Bronze Platebody. Hard Leather Cowl (key 7): Loadout Head, `CurrentHeadWearable`.
  - **Luis confirmed visually ("Yep looks good!", ~17:45 UTC):** platebody, cowl and Mithril axe all show correctly on Claude from his GFN client.

## R2 brain bridge on the client: live, hot-started without a restart (2026-10-25, about 17:47 UTC, client build 26162923, Shockbyte world)
- **Hot start through the command runner works.** `client_mod/commands/bridge_start.lua` `loadfile`d `client_mod/scripts/client_bridge.lua` into the running DWClient. That file in turn loaded a fresh instance of `mod/scripts/bridge.lua` and the four client modules (chat, move, sense, inventory: all `ok`). It then started a 100 ms `LoopInGameThreadWithDelay`. No errors in `logs/client/mod_20261025T174657Z.jsonl`. `chat.start` was re-run harmlessly (idempotent).
- **Round trip, brain to client and back** (`client_io/bridge/brain_to_client.jsonl` → `client_to_brain.jsonl`):
  - `ping` over 10 calls: 64–169 ms (mean about 115 ms, mostly the 100 ms poll);
  - `get_state`: 215 ms including census and inventory.
- **`get_state` read live** (read-only; no movement, no chat):
  - position, health 100/100, name `Claude`, skills, stamina;
  - `players` = Luis's character **`Zezima`** at 20.9 m; `players_online` `["Claude","Zezima"]`;
  - 2 Kebbits (passive);
  - stones, an ash sapling and dropped loot (ash logs, hide, antler, raw meat) in `nearby_items`;
  - `inventory` (hotbar + bag) and `gear` (Head Hard Leather, Body Bronze, Legs Adventurer's, HeldRight and HeldLeft Mithril Logging Axe);
  - `not_implemented` = only `places` and `structures`.
- **Capabilities** (dynamic, from the loaded modules):
  - `get_state, say, follow, stop, go_to, drop`, plus the debug tools `bridge_status, me, census, inventory, move_status, equip, unequip`;
  - `discover()` gives planner skills `go_to, follow, stop, drop`;
  - absent: attack, gather, craft, give, pickup, cast, sleep, wake, look, interact, place, and the rule tools.
- **Implications for the brain:**
  - On this world Luis's chat sender name is his character name `Zezima`, so `command_received.player` is `Zezima`.
  - An equipped item that came from the hotbar stays in its hotbar slot (see the equip entry above), so it appears in both `inventory` and `gear`.
- **Not yet exercised live:** say, follow, go_to, stop and drop through the bridge. Their owners' modules are being tested separately, and the brain was not started. **UNVERIFIED** until a supervised run.
- **Death and the gravestone (verified 17:43-17:50 UTC):** Claude died while standing still after a follow test. On death the hotbar and bag go into a **`BP_PlayerGravestone_C`** (`AGravestone : AWorldActor`). Its contents are a `BP_Components_WorldItemInventory_C` (`GetInventory()`; read from the client: Torch, Bronze Shield, Mithril Pickaxe, Mithril Logging Axe, Adventurer's Tunic, Bone Dagger). The **worn armour stays on**. The grave was placed at the death spot, 28 m from the respawn point at the start-area lodestone. `CanPlayerAccessGravestone(pc)` returned false on the client, but that did not matter. Recovery: walk within 1.2 m (move.lua go_to). The game's detector then targets the grave with prompt **"Take All"**, and **one plain IA_Interact press** puts every item back in its original hotbar slot, durability unchanged. The grave actor then disappears. No hold and no UI were needed. Respawn re-uses the same pawn object.
- **Cause of death = dehydration (verified):** the pawn's `BP_Components_PlayerDamage` (`DamageComponent`) `FatalDamageInfo` held `KilledBy` = his own pawn, `KilledByPowerLevel` -1 and `KilledByStatusEffectFlags` = 64. The flags are a bitmask with bit n = `EStatusEffectType` n (5 Starvation, 6 Dehydration), so 64 = dehydration. The vitals watcher then recorded it live: once hydration reached 0 (about 17:52:58), the server multicast **1.0 damage per second**, class None, `TypeDamages[].StatusEffect` = Dehydration, `Instigator` = himself. He went from 100 to 45 HP in 55 s. **The wiki's "0 hydration cannot kill" does not hold in this build:** he died of it twice (Luis saw the second death). Survival data (live, pawn components):
  - `HydrationComponent`: Start 50, `DecayRatePerHour` 5.5 (in-game hours: about 1.4 points per real minute), `HydrationRemovedOnDeath` 10, `LastQuarterDecayRateMultiplier` 0.5. `HydrationEffectLevels` at 0/25/50/75/100 apply `GE_Hydration_Damage` (at 0 only) plus the stamina-regen scale and delay GEs.
  - `SustenanceComponent`: Start 50, decay 4.15/h, RemovedOnDeath 10. Levels at 0 apply `GE_Sustenance_Damage` plus health-regen GEs.
  - `EnduranceComponent` (rest): its levels at 0/25/50 scale max stamina, carry weight and max sustenance/hydration.
  - Getters: `GetCurrent{Hydration,Sustenance,Endurance}()` / `GetMax*()`.
  - A fresh character starts at 50/50 and is dry in about 35 real minutes.
- **Max health:** `HealthComponent.MaxHealth` reads 0 on players (`BP_Components_Health_C`, a `UPlayerHealthComponent : UHealthFromAttributeComponent`, max comes from an attribute). Use `GetMaxHealth()` (100 for Claude, 250 for Zezima).
- **Vitals watcher (`sense.vitals_start`, verified):**
  - A post-hook on `/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect` **fires on the client** for each damage event the server multicasts. Read-only param reads of `FDominionDamageEvent` work: `Amount`, `AmountAbsorbedByShield`, `DamageClass`, `TypeDamagesArray.TypeDamages[].StatusEffect` / `.Types`, `Instigator`, `Source`, `bIsFatalHit`.
  - The point-damage variant and `OnRep_FatalDamageInfo` are hooked too, but no event has been seen on them yet.
  - **`HealthComponent:OnRep_AuthoritativeHealth` never fired** for these changes (it may not be routed through ProcessEvent, or health is predicted locally). A 1 s poll of `GetAuthoritativeHealth()` catches every change.
  - Output: `client_io/events/vitals.jsonl`.
- **Food and drink in item data:** `UFoodItemData` (`StatSustenance`, `StatSoulScourge`, `AmountToHealOnConsume`, `SustenanceRowHandle`) and `UDrinkItemData` (`StatHydration`, `StatSoulScourge`, `bAllowConsumptionWhenHydrationFull`, `HydrationRowHandle`), both `UBuffItemData : UConsumableItemData` (`UseVerb`, `ItemUsageDelay`, `GameplayEffectsToApply`). Drinks in the dump: `ITEM_Consumable_Water_{Clean,Dirty,Cactus,Wither}`. `inventory.describe_item` now tags `consumable = food | drink | potion` from the data class.
- **Water from a source (RESEARCH, not yet tried):**
  - The wiki and guides say interacting (E, repeatedly) with a pond, lake or river adds **Dirty Water** to the inventory with no container needed. Dirty Water gives +10 hydration and +20 Soulscourge (toxicity: damage over time at 100). A Campfire turns Dirty Water plus fuel into **Clean Water** (+25 hydration).
  - In the dump, the PlayerController's `UFluidController` has `Server_TryTakingInstantly`, `Server_TryStartTaking`, `Server_TryFillingInstantly`, `Server_OnTransferPanelOpen(FluidContainer)` and `TakeSpeed` / `FillSpeed` curves. That is probably what the water interaction drives.
  - No water-source actor class was found in the server dump (water bodies are probably streamed level actors).
  - Plan: near water, the census lists the `InteractionComponent` with the water prompt; press interact once per Dirty Water; drink only when needed; boil at a campfire when one is built.
  - Sources: dragonwilds.runescape.wiki/w/Hydration, /w/Dirty_Water, /w/Clean_Water; primagames.com/tips/how-to-get-clean-water-in-runescape-dragonwilds.
- **Client hang (17:53:54 UTC):** the game thread stopped (game log ends 17:53:34, mod log 17:53:54, 0.03 s of CPU in 3 s, process alive at 1.98 GB) with **478 MB of free RAM** on the VM. A RAM-pressure stall is the likely cause; it is reported to main and was not restarted by this agent.

## Traversal (R2) (2026-10-25, from the reflection dump of server build 26161880 + the client UE4SS.log; client build 26162923 not dumped; no live calls made)
Research and design: `docs/research/2026-10-25-traversal.md`.
- **There is no mantle, ledge-grab, climb, vault or glide.** The dump has 0 classes or actions for Mantle, Climb or Glide; the "Vault" hits are the Vault Core item. Traversal is jump-based: jump, coyote time, double jump, Air Dash, Phase Dash, Windstep, Breakfall, swim, kebbit burrows.
- **Input actions** (`/Game/Gameplay/Inputs/Actions/`):
  - `Basic/IA_Player_Jump`, `IA_Player_Sprint`, `IA_Player_Evade`, `IA_Movement`, `IA_VerticalMovementUp/Down` (purpose UNVERIFIED), `IA_Mount`;
  - `Spellcasting/IA_Spellcasting_QuickAccess0..7` (the cast route for Windstep and Phase Dash);
  - `UI/IA_UnstuckCharacter_Held` (the game's own unstuck; the pause menu `UPauseMenuScreen` has `ProgressButton_Unstuck`, `TeleportToStart()`, `RestartAgilityCourse()`);
  - `Agility/IA_AgilityCourse_Banner_*`.
- **`UDominionMovementComponent` (Dominion.hpp:20581):**
  - Dash: `DashDistance`, `DashStaminaCost`, `DashCooldownDuration`, `MaxFallDistanceForDash`, `DashDistanceToVelocityCurve`, `DashPerkData`, `DashBlockingTags`, `DashMontage`, `bWantsToDash`, delegate `OnDash(bool bWasPhaseDash)`.
  - Phase Dash: `MaxPhaseDashCharges`, `PhaseDashEffectDuration`, `MaxPhaseDashesMidAir`, `EnablePhaseDashes()`, delegates `OnPhaseDashActivated/Deactivated`.
  - Double jump: `GravityToDoubleJumpVelocityCurve`, `DoubleJumpBlockingTags`, `MaxFallDistanceForDoubleJump`, `MinimumAccelerationForDirectionalDoubleJumpAndDash`, `DoubleJumpMaxHorizontalSpeedDuringDash`.
  - Falls: `MinFallDamageHeight`, `MaxFallDamageHeight`, `FallDamageBlockingTags`, `BreakfallMontage`, `BreakfallPerkData`, NetMulticast `Multicast_ApplyFallDamage(float, bool bShouldPlayRollAnim)`, `SetFallDamageImmune`.
  - Jump gating: `bJumpBlocked` (Replicated), `JumpInhibitors`, `JumpBlockingTagQuery`, `IsJumpEnabled()`.
  - Windstep: `OnLandedWindstepEvent`.
  - Attribute classes (GE-modified, e.g. by Windstep): `JumpHeightAttributeClass`, `GravityScaleAttributeClass`, `AirControlAttributeClass`, `RunSpeedAttributeClass`.
- **`ADominionPlayerCharacter` (Dominion.hpp:9779; UHT DominionPlayerCharacter.h):**
  - Perk and curve fields: `DoubleJumpSkillPerk`, `GravityToMaxUpwardsVelocityForDoubleJumpCurve`.
  - Coyote time: `LedgeForgivenessTime`, `IsInLedgeForgivenessTimeWindow()`.
  - Jump events: `PlayerCharacterJumpedEventDynamic`, `OnDoubleJump()` (BlueprintImplementableEvent).
  - **`ReplicatedJumpCurrentCount` (int8, `ReplicatedUsing=OnRep_ReplicatedJumpCurrentCount(int8 PreviousJumpCount)`)**: the per-jump signal other clients receive.
  - `bIsRunningAgilityCourse` (ReplicatedUsing); `DoDash()` (BlueprintCallable, **Exec**); `WindstepTag`, `WindstepXPEvent`, `JumpXPEvent`.
- **ACharacter (engine, reflected):**
  - `ReplicatedMovementMode`, `bProxyIsJumpForceApplied`, `ProxyJumpForceStartedTime`, `JumpMaxHoldTime`, `JumpMaxCount`, `JumpCurrentCount`;
  - `OnJumped`, `OnLanded(FHitResult)`, `K2_OnMovementModeChanged`, `OnWalkingOffLedge`, `LaunchCharacter`, `CanJump`.
- **UCharacterMovementComponent (engine, reflected):**
  - `K2_FindFloor(FVector CapsuleLocation, FFindFloorResult& out)` and `K2_ComputeFloorDist(...)`: the CMC's own capsule floor sweep at any location.
  - `GetMaxJumpHeight()`, `GetMaxJumpHeightWithJumpTime()`, `GetGravityZ()`, `IsFalling/IsMovingOnGround/IsSwimming`;
  - `CurrentFloor` (FFindFloorResult {bBlockingHit, bWalkableFloor, bLineTrace, FloorDist, LineDist, FHitResult}), `MaxStepHeight`, `WalkableFloorAngle`, `LedgeCheckThreshold`, `PerchRadiusThreshold`, `AirControl`, `GravityScale`.
- **Traces:**
  - `KismetSystemLibrary:LineTraceSingle/SphereTraceSingle/CapsuleTraceSingle` (bool return + `FHitResult&` out). `FHitResult` nests `FVector_NetQuantize`, `TWeakObjectPtr` and `FActorInstanceHandle`, so **out-param marshalling from UE4SS is UNTESTED** (risk register R15 class).
  - `GameplayStatics:Blueprint_PredictProjectilePath_Advanced` (struct params: avoid).
  - Dev server: `NavigationSystemV1:NavigationRaycast(ctx, start, end, FVector& HitLocation, filter, querier)` (flat FVector out, the same pattern as K2_ProjectPointToNavigation).
- **Navmesh link machinery in this build:**
  - `ARecastNavMesh.bGenerateNavLinks` + `FNavLinkGenerationJumpDownConfig` {bEnabled, JumpLength, JumpDistanceFromEdge, JumpMaxDepth, JumpHeight, JumpEndsHeightTolerance, SamplingSeparationFactor, FilterDistanceThreshold, LinkBuilderFlags, Down/UpDirectionAreaClass, LinkProxyClass} (UE 5.5+ experimental auto links); `K2_ReplaceAreaInTileBounds`.
  - `ANavLinkProxy` {PointLinks `TArray<FNavigationLink>`, SegmentLinks, SmartLinkComp, OnSmartLinkReached, ResumePathFollowing}.
  - `UNavigationPath` exposes only `PathPoints` (FVector), so link segments can't be identified from a path.
- **Perks** (`/Agility/Gameplay/Character/Player/PerksV2/`): `PerkV2_Agility_DoubleJump`, `_AirDash`, `_Spell_PhaseDash`, `_Breakfall`, `_GreaterBreakfall`, `_Hopper`, `_Spell_Windstep_Upgrade` (Wind Stomp), `_KebbitBurrows_{Common,Wild,Dark,Desert,Razorbacked}`, `_Spell_Recall(_Upgrade)`; `PerkV2_Attack_JumpAttack`, `PerkV2_Attack_SprintAttack`.
  - `USkillPerkData.InputActionDisplay` (`FPerkUnlockInputActionDisplay` {InputAction, InputActionMappingContext, ActionDescription}) names the input that triggers a perk. Read it for Air Dash.
  - Query: `pc.SkillPerkComponent:IsPerkUnlocked(USkillPerkData)`.
  - Levels (BisectHosting guide, not the game): Windstep 5, Double Jump 10, Hopper 22, Common Burrower 27, Air Dash 32, Breakfall 35, Wind Stomp 40, Phase Dash 44.
- **Windstep is a super-jump, not a dash** (data/spells_26161880.json): Instant cast, `allow_while_falling=false`, 5 Air, 3 s cooldown.
  - It applies `GE_Windstep` (jump height, gravity scale, air control and fall-damage modifiers), which is removed on landing; module `InhibitJumpOnLanding`.
  - Wiki: "jump up to 16 m, slow fall, 7 s to use".
- **Observing other players on the client (simulated proxy), from the dump:**
  - `ReplicatedJumpCurrentCount` (OnRep) and `ReplicatedMovementMode` (→ `IsFalling`).
  - `UPlayerEvadeComponent:Multicast_StartEvade(int32 MontageIndex, bool bSurge, FRotator)` (NetMulticast).
  - `Multicast_ApplyFallDamage`; `GameplayTagsComponent.ReplicatedGameplayTagStackContainer` (Replicated).
  - `USprintComponent` replicates only `bMovementBlocked`, so infer sprint from speed.
  - None of these has been read live on the client yet.
- **Caution: `JumpMaxCount = 2` on Claude is not proof of double jump.** Claude's character is Agility 1, and Double Jump is Agility 10 (`DoubleJumpSkillPerk`). Verify with `IsPerkUnlocked` and the Z velocity after the second `Jump()`.
- **Stuck-in-gap evidence (client UE4SS.log, 2026-10-25 18:52-18:54 UTC, follow test on Shockbyte):**
  - Claude's capsule was fixed at about (71.6, 1862.0, -34.6) m for over 90 s. The nav path was partial, ending at Z -35.2 m beside him.
  - The goal and the breadcrumbs he aimed at were at Z about -31.3 m, 3.3 m above him.
  - The trail index jumped 2 → 21 in about 2 s because breadcrumb advance is 2D.
  - The jump/double-jump ladder repeated every ~6 s with 0-7 cm progress.
- **Fed and watered, then recovered the grave again (verified 18:00-18:05 UTC, after the client restart):**
  - Luis dropped Forager's Sandwich x49 and Pumpkin Spice Infusion x49. Claude walked 8.7 m to them (move.lua go_to) and collected both with 2 interact presses, landing in hotbar 1 and 2.
  - **Drink:** hotbar key 2 (`UseItemInSlot(1)`) took hydration from 18.6 to 95.8.
  - **Eat:** the stay-fed reflex (`inventory.reflex_start`, a game-thread loop) fired by itself at 18:01:46 and used hotbar key 1. Sustenance went from 18.5 to 98.0.
  - **Item data classes:** the live classes are Blueprint subclasses (`/Game/Gameplay/Items/Consumables/BP_Consumables_Drink.BP_Consumables_Drink_C`), so food and drink are recognised by the presence of the `StatSustenance` / `StatHydration` properties, not by class name. Their categories are `Item.Food` and `ItemFilter.Type.Consumable.Drink`.
  - **Second grave:** `BP_PlayerGravestone_C` at (71.63, 1862.03, -35.48) m, straight-line go_to arrived at 0.6 m, and one "Take All" press returned all 6 items. They went to the first free hotbar slots: the Torch and Shield moved to slots 7-8 because food and drink now occupy 1-2.
  - Re-equipped the axe with hotbar key 4.
  - **The grave spot is a dead end toward the open ground east:** two straight go_to attempts to Zezima from there failed "stuck" after about 1 m. Backtracking to the lodestone (straight, 0.98 m) and then go_to Zezima reached 2.98 m from him at (89.48, 1851.2, -31.42) m.
- **Measured live by the locomotion agent (Claude's client, 2026-10-25):**
  - Physics: JumpZVelocity 807.9, GravityScale 1.85 (`GetGravityZ` −1813), `GetMaxJumpHeight` = `GetMaxJumpHeightWithJumpTime` = 180 cm, `JumpMaxHoldTime` 0.
  - Limits: `MaxStepHeight` 45, `WalkableFloorAngle` 45.5, `MinFallDamageHeight` 1500 / `MaxFallDamageHeight` 2860 cm, capsule half-height 88.
  - **`IsPerkUnlocked(DoubleJumpSkillPerk)` = false**, so the caution above is confirmed: no double jump at Agility 1.
  - `LineTraceSingle` from Lua works on the dev server and the client (about 1 ms). The out table fills nested (`ImpactPoint.Z`, `ImpactNormal.Z`, `Distance`, `Time`).
  - `bStartPenetrating` reads junk (it shares bitfield byte 0xAD with `bBlockingHit`); use `Distance == 0`.
  - `K2_ComputeFloorDist` works on the dev server.

## Raising Claude's stats via Claude.json: RESOLVED, the edit is NOT active (investigated 2026-10-25 19:15-19:26 UTC, client build 26162923, Shockbyte world "The Goochlands" GUID 78BEF9BB90BD45109AB14AC58AE159BE; read-only)
History:
- 19:10: a local merge of Zezima's skills into `Claude.json` had no effect (backup `C:\GameServers\backups\claude_char_20261025-190851.json`).
- 20:07 local: Luis's edited copy came down from Steam Cloud: SaveCount 17, 12 642 bytes, XP 1 000 000 in six skills. A pre-launch copy is at `C:\GameServers\backups\claude_local_before_cloud_200726.json`.
- After that, Claude joined at 19:08 UTC, the watchdog restarted the client, and it rejoined at 19:18 UTC.

**Actual live levels** (`client_mod/commands/stats_skills.lua`, read-only, `pc.SkillComponent`, 19:19 UTC):
- **Every skill is level 1 with 0 XP, except Agility, which is level 3 with 70 XP.** Total level 14.
- Power level `BP_GetPowerLevel()` is 2. There are 0 perk runtime states, and `IsPerkUnlocked(DoubleJump)` is false.
- `sense.me`'s total_level is correct: it is `GetTotalSkillLevel()`, which equals the sum of the per-skill `GetSkillLevel` (11 × 1 + 3 = 14).

**The XP curve** (`GetTotalXPNeededForLevel`):

| Level | 2 | 3 | 5 | 10 | 20 | 30 | 40 | 50 | 60 | 70 | 80 | 90 | 99 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| XP | 33 | 70 | 156 | 463 | 1 798 | 5 367 | 14 929 | 40 594 | 86 998 | 147 842 | 223 122 | 312 838 | 1 000 000 |

- `MaxLevel` is 99, so the edited XP values were valid: 1 000 000 = 99, 40 594 = exactly 50, and the rest are about 73-91.
- Skill ids in the JSON are each `USkillData.PersistenceID`, for example `4zYUGF5u_0KbMLkWJmmBbQ` = skill_woodcutting and `pJggvotwOkuoc98igUn7xA` = skill_agility.

**Where the live character comes from: the Shockbyte server's own copy, not Claude.json.**
1. **The client does send the edited file.**
   - Client log at 19:08:22: `Remote Character load complete … slot[Claude]`, then `Data Buffer compressed [LZ4] was[12642]Bytes`, then `Started player profile stream. Handle[242] Size[12642]`.
   - 12 642 bytes is exactly the size of the edited SaveCount-17 file.
   - On the dev server the receiving side is visible: `PLAYER - CLIENT SAVE`, `Player profile stream completed`, then `LoadStateFromJson`. Examples: Zezima at 13:35-15:54 and the dev-account Claude at 16:51:54.
2. **The live state matches neither stream.**
   - Join 1 streamed 1M XP and an empty inventory (the edited copy was taken after the 18:21 death, with the items in the grave). The result was 0 XP and a 13-item inventory.
   - Join 2 streamed the game's own 19:11 save, which had Agility 83 XP. The result was **Agility 70**. XP only goes up, so the live state is an older server-held snapshot.
   - The live position and playtime also continue from neither file. So the server replaced the client's JSON with a state it kept itself.
3. **The server writes the local file, not the other way round.**
   - `ADominionPlayerControllerBase::Client_SaveToDisk(FDomClientDiskSave)` is a server→client RPC. `FDomClientDiskSave` has no reflected fields.
   - A read-only post-hook (`client_mod/commands/stats_savehook.lua`, output in `client_io/events/savehook.jsonl`) fired at **19:25:39Z, the same second `Claude.json` was rewritten** (SaveCount 25, XP still 0 / Agility 70, `worlds_playtime[78BEF9BB…]` = 1792956339 = 19:25:39 UTC).
   - The siblings are `Client_LoadFromDisk(Handle, FPlayerCharacterInfo)` and `Client_SetHasEditedProfile(bool)`.
   - The game therefore **overwrote the edited Claude.json** (SaveCount 18-25, every few minutes), and Steam Cloud re-uploaded it (`steam_autocloud.vdf` at 20:17).
   - `Claude.json.backup` rotated at 19:20 UTC. The only surviving copy of the 1M edit on this VM is `C:\GameServers\backups\claude_local_before_cloud_200726.json`.
4. **The server-side copy mechanism** (from the dump, plus Jagex's notes):
   - The world has a SPUD-persisted `ACachedCharacterStates` actor. Its field is `TArray<FCachedCharacterState{FDomCharacterGuid CharacterGuid; FString State; float LastUpdated}>`, with the `SaveGame` flag. `UWorldSaveUpgradeHelper` also carries `CachedCharacterStates`.
   - On Claude's client this actor is a non-replicated level actor with 0 entries (`stats_cache.lua`). On the dev server it is also empty right now, with no players connected (`mod/experiments/charcache_probe.lua`). So the **Shockbyte server's** contents could not be read; that file is the group's world, so it was not touched.
   - Jagex's 1.0.0.7 patch note (2 Oct 2026): progress was "not carrying over between worlds"; "Your most frequently visited world will override on login"; "The save data will pull the world that you have spent the most time in (specifically the world with the most save states logged in it)".
   - Jagex's 0.11.0.8 note (7 Apr 2026): "Players connecting to a dedicated server should not experience rollbacks on progress from previous sessions".
   - Together these mean that a world keeps per-character states, and on login they override the client's file.
   - In `meta_data.worlds_playtime`, the value is the Unix time of the last save in that world, not a playtime. In the edited file it was 18:23:40 UTC, older than the server's copy.
5. **Ruled out:**
   - Steam Cloud re-sync: the 19:08 stream was the edited file itself.
   - A different slot or the `.backup`: the slot is Claude, and the size matches.
   - A different XP-to-level conversion: the curve tops out at 1M = 99.
   - `sense.me` reading stale data: the live read agrees.
   - The client log has no cheat/invalid/sanitise lines. The only flags are `SetPawn: bHasLoadedCharacterState [false], bCharacterSaveDataIsValid [false]`, and those print false on every client join; on the server they become true.
   - Validation that clamps XP is not excluded, but it cannot explain the inventory or the Agility 83 → 70 change.

**What would make an edit take effect (not done, needs Luis):**
- (a) Edit or remove Claude's `CachedCharacterStates` entry in the Shockbyte world save, with the server stopped. Claude's character GUID is `D06CFBE34D95AB743CE28EBE2C0DBBC7`. **That is the group's real world**, so it is Luis's call, with a backup first.
- (b) Untested: an edited Claude.json whose `worlds_playtime[78BEF9BB…]` timestamp (and maybe SaveCount) is newer than the server's copy, uploaded while the client is closed. This applies only if the override is "newest wins"; the 83 → 70 rollback suggests the server copy may win regardless.
- (c) Prove the mechanism on the dev server first. Join a character there with a 1M-XP file (a fresh world has no cached state, so `LoadStateFromJson` should apply it), read `GetSkillLevel` on the server, then rejoin with a lower file and check which one wins.

## R2 client perception for the brain: look / inspect / get_state digest live (2026-10-25, about 18:11-18:20 UTC, Shockbyte world, read-only)
- **Setup:** `client_bridge.lua` was hot-reloaded live (`bridge_start.lua`), with no client restart. Capabilities now add `look`, `inspect` and `interact`, so the brain's planner skills become `go_to, follow, stop, drop, interact` once the brain restarts.
- **`get_state`** (262 ms) now carries:
  - `hydration` 48.7/100, `sustenance` 63.5/100;
  - `held` "Mithril Logging Axe";
  - an `interactables` list.
- **The brain's digest from it, live:**
  - `You: HP 100%, water 49%, food 64%, holding Mithril Logging Axe`
  - `Creatures: Kebbit x5 (19 m, ..., HP 60/60)`
  - `Around: Stone x16 (9 m); Ash Log x3 (9 m, chop, needs Hatchet T1, HP 80/80); ...`
  - `Usable: Crafting Starting Bench x2; Base Building Crate x3; Doric (NPC, prompt "Talk"); Loot ...`
- **`look`:** about 200 ms for 52 things within 30 m.
  - `about="tree"` matched only "Ash Tree Seed". **Standing trees are foliage instances, not actors, so the client census does not see them.** Felled ash logs, stones and saplings are seen. A foliage census on the client is the open item (the server body converted foliage).
  - `about="grave"` found none: the grave had already been taken.
- **`inspect`** of a stone returned `{kind: gatherable, verb: gather, prompt: "Collect", item: ITEM_Resources_Stone, available: true}`.
- **Not exercised live:** `interact` (offline tests only: approach, aim, wait for the detector to target the actor, one IA_Interact press, then verify the target is gone or the inventory grew), `attacked` and `vitals_low`. Gravestone Take All by one press at 0.6-1.2 m was verified by the inventory agent; see its entry above.
- **Background services:** `bridge_status.services` reports chat, vitals and fed_reflex as `running`. Main had started them by hand at 19:13 local; the bridge now supervises them, so a client boot starts them (offline-tested; first live boot pending).

## Client combat (R2) (2026-10-25, client build 26162923, Shockbyte world; server build 26161880 dump for class layouts)
Modules: `client_mod/scripts/arbiter.lua` (pawn ownership), `client_mod/scripts/combat.lua` (fight-or-flight, weapon choice, engage, defend, flee, loot, re-equip), `client_mod/scripts/weapons_data.lua` (generated by `tools/gen_weapon_profiles.py` from `data/items_26161880.json`). Commands: `combat_probe` (read-only), `combat_probe_live` (read-only), `combat_start`/`combat_stop` (reflex), `combat_status`, `combat_test` (commanded attack on the nearest Kebbit). Offline: `lua client_mod/tests/test_combat.lua` (70 checks: arbiter, pure decisions, whole fights against a fake engine).
- **Combat input actions on Claude's pawn (read live, read-only, `combat_probe`):**
  - `pawn.PlayerInputBufferInputActions` (`FPlayerInputBufferInputActions`, Dominion.hpp:6006; the same struct feeds `UPlayerInputBuffer`): `PrimaryAction` = **IA_PrimaryAction** (attack), `SecondaryAction` = **IA_SecondaryAction** (block; the catalog's `secondary.kind = block`), `SpecialAction` = **IA_SpecialAction**, `EvadeAction` = **IA_Player_Evade**, `MountAction` IA_Mount, `MovementAction` IA_Movement.
  - Primary/Secondary/Special: `ValueType` 0 (Boolean), `bConsumeInput` true, one trigger **`InputTriggerDown`** (fires every frame while held: a tap = a few frames of injection, a block = inject every frame). Evade: Boolean, no triggers.
  - Lock-on: `pawn.LockOnTargetingComponent` (`BP_Components_LockOnTargeting`): `ToggleLockOnInput` = **IA_ToggleLockOnTargeting** (Boolean, **`InputTriggerPressed`**: inject one frame, then nothing), `SwitchTargetInput` IA_TargetSwitchLockOnTargeting, `MaxTargetDistance` 3200, `TraceDistance` 3000, `TraceRadius` 500, `ScreenSpaceAngleTolerance` 110; its `LockOnCameraActor` (`BP_LockOnCameraActor_C`) and `TargetingWidgetInstance` (`WBP_LockOnTargetOrb_C`) exist on the headless client. `FLockOnTarget CurrentTarget` has **no reflected fields** (CXX: empty struct), so the locked target cannot be read.
  - `BP_Components_PlayerMeleeAttack_C`: `InputBufferingDuration` 0.5 s (presses up to 0.5 s early are buffered, so a human-like cadence chains combos), `EarlyOutActions` = IA_Movement, IA_Player_Evade, IA_Player_Jump, IA_Player_Stealth (these cancel a swing), aim assist `MaximumAngleAimAssist` 45, `ScreenSpaceRadius` 0.2 (camera based).
  - `BP_Components_PlayerBlocking`: `BlockingAngle` 120, `ParryWindowLength` 100 (ms?), `MinimumBlockDuration` 0.75 s, `BareHandsBlockingDamageNegation` 5. `BP_Components_Evade`: `InputAction` IA_Player_Evade, `IsEvadeEnabled()` true.
  - Rotation: `bUseControllerRotationYaw` false, `CharacterMovement.bOrientRotationToMovement` **true**, `RotationRate.Yaw` 540: the body turns only toward movement, so facing a target while standing needs a short movement nudge (or lock-on).
  - Power level: **`pawn:BP_GetPowerLevel()` = 2**; `DominionRuntimeBlueprintLibrary:GetCurrentEquipmentPowerLevel(pc)` = 1 (nothing held at that moment). Creatures: `PowerLevel` / `GetAIPowerLevel()` (Kebbit 1). `SpecialChargeComponent:GetSpecialCharge()/GetMaxSpecialCharge()` 100/100; stamina 80/80 (60/60 later, after endurance dropped).
  - Kebbits nearby: `BP_AI_Kebbit_Character_02_C`, HP 60 (`GetMaxHealth` 60), Archetype 4 (NeutralUntilAttacked), PL 1, `AiAttackComponent` = `BP_Kebbit_AiAttackComponent`. **`AIAttributesComponent.DamageTypeAffinities` is empty on the client** for Kebbits (not replicated, or none): weaknesses must come from hit outcomes or priors.
- **Signals combat listens to (hooks, read-only):** `DamageComponent:Multicast_Apply[Point]DamageFromGameplayEffect` (who hit whom, `TypeDamagesOutcome` per type for weakness learning; a second Lua hook beside sense.lua's vitals hook) and `AiAttackComponent` / `AiRangedAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackClassId, AttackId, bFromCombo)` (NetMulticast: an AI attack starting, used as the telegraph). Live firing of the AI-attack multicast on this client: UNVERIFIED (Kebbits do not attack).
- **Weapon data:** catalog profiles per item id: Bone Dagger PL 2, 7-step chain mean 11.6 dmg, press every ~0.77 s (input-window end), 10 stamina per swing, special Lacerate 21 dmg / 25 charge; Mithril Logging Axe PL 6, Chop 10 dmg every ~1.29 s, 4 stamina; Mithril Pickaxe 10 dmg every ~1.53 s; Bronze Shield block 39; Torch block 26. The catalog's `damage_multiplier` (axe 6.8, pickaxe 8.2, dagger 1.9) is unexplained, so the score does not use it.
- **Search (search-before-building):**
  - Arbitration: Behavior Multi-Queues (Cutumisu & Szafron, AIIDE 2009, webdocs.cs.ualberta.ca/~duane/publications/pdf/2009aiideMC.pdf: interruptible and *resumable* behaviours by priority, used in Neverwinter Nights); subsumption (MIT 6.189 arbitration lecture, courses.csail.mit.edu/6.189/fall2005/pub/lectures/Releases/2005_10_12_lecture10_arbitrationv4.pdf); BT lower-priority observer aborts (docs.unity3d.com/Packages/com.unity.behavior@1.0/manual/observer-abort-mechanics.html); Game AI Pro 360 "Behavior Selection Algorithms" (TOC only). No Lua library for this. Decision: **adapt** (priority slot + suspended stack + leases), build ~250 lines.
  - Fight or flight: utility AI with time-to-die comparison (gamedev.net/forums/topic/686840-help-me-understand-utility-ai); nothing more specific found. Decision: **adapt** (hard vetoes + utility + hysteresis).
  - Engage loop: mineflayer-pvp (npmjs.com/package/mineflayer-pvp: followRange / attackRange / viewDistance) and the nxg-org advanced fork (shield handling). Decision: **adapt** the shape.
  - Dragonwilds combat rules: parry = block pressed just before the hit; block, dodge, attack and sprint all cost stamina; specials use their own meter; neutral evade is short with i-frames, directional rolls go farther (mobalytics.gg/gamebase/guides/runescape-dragonwilds-combat, deltiasgaming.com/?p=205876, games.gg combat guide). No source describes lock-on.
  - Enhanced Input: Epic docs for InjectInputForAction / InjectInputVectorForAction / StartContinuousInputInjectionForAction (the continuous variant takes FInputActionValue, which UE4SS cannot build, so holds are per-frame vector injections). No UE4SS-specific example found.
- **UE4SS pitfall (verified 18:23 UTC): a missing property is NOT nil.** Reading a property an object does not have (e.g. `WearableEquipmentData.StatSustenance`) returns a non-nil invalid `TrivialObject` userdata (`IsValid()` false). So `obj.Prop ~= nil` is no existence test. Use `obj:IsA(StaticFindObject("/Script/Dominion.FoodItemData"))` (works from Lua) or `U.valid(...)` on object-typed fields.
  - **Live bug this caused:** the stay-fed reflex classed the Mithril Pickaxe as "food" and pressed its hotbar key repeatedly from 18:20:46. Claude never drank, and a Giant Rat killed him at 18:21:04 with hydration at 10.9.
  - **Fix:** class-based detection (`inventory.consumable_kind`). Before each press, `inventory.use` re-checks the exact slot (same item, not equipment, the required class). The reflex verifies the stat rose 4 s later and marks the item bad otherwise.
- **Client hangs and crash, triage (18:30 UTC, no game PDB; frames are export-relative):**
  - **17:53:54 hang** (cdb stack `logs/client/stack_6400_175704.txt`):
    - The GameThread is in `WaitForSingleObject`, about 13 frames deep inside game code. Above that sits a UE4SS frame (`UE4SS!…StartCallbackGarbageCollector+0x675`), which is UE4SS's engine-tick hook calling the original tick. Above that are only 7 frames to the thread start.
    - **No Lua frame is on the game thread.** So the wait is inside the engine's own tick: a task or fence that never completes. It is not inside one of our Lua calls or hooks.
    - The RenderThread and FAsyncLoadingThread also wait idle. VM free RAM was 478 MB.
  - **18:27:42 hang:** the last mod line (an `inv_list` command run) came 2 s after the reflex's bag "use" (`InventoryUIAPI:HandleInternalUseItem`, 18:27:40), so the game thread was still alive after that call. No stack was captured (main killed the process).
    - Mitigation: the reflex now uses **hotbar items only** (`REFLEX_CFG.allow_bag = false`). It logs `no_hotbar_<kind>` when food or drink is only in the bag.
  - **18:08:42 crash** (UE4SS dump `…/Win64/ue4ss/crash_2026_10_25_19_08_42.7381637.dmp`, local time):
    - An access violation in game code, called from a **Lua UFunction call inside a game-thread callback**: the same UE4SS hook site `+0x65a` → `Lua::call_function` → `process_lua_function` → game native → AV.
    - It came 2 s after `disconnect.lua` (18:08:40). The likely cause is a game-thread loop (vitals poll, reflex, move or bridge) touching objects during world teardown.
    - Mitigation: the vitals poll and the reflex tick return immediately while `_G.DW_PAUSE` is set. Disconnect and travel commands should set it, or stop the loops, first, and clear it after the pawn exists again.

## Client ops: boot_and_join, watchdog, smoke test (R2.15, R2.16) (2026-10-25, client build 26162923)
Files: `tools/client_lib.ps1` (shared), `tools/client_boot.ps1`, `tools/client_watchdog.ps1` + `tools/start_client_watchdog.ps1`, `tools/stop_client.ps1`, `tools/client_smoke.ps1`, probe `client_mod/commands/boot_probe.lua`, `smoke_*.lua`; offline tests `tests/test_client_ops.py` (fake client: copied PING.EXE + a Python thread that plays the command runner). Runbook: RUNBOOK-patch.md §10.
- **Read-only probe (verified live, 1.9 s round trip):** the map comes from the local PlayerController's path (`... /Game/Maps/World/L_World.L_World:PersistentLevel.BP_PlayerController_C_...`). The probe also reads `MainMenuUIAPI:GetCurrentScreenType()` (0 in the world), `DomMatchmakerSubsystem:IsUserLoggedIn()`, `pc.Pawn`, the count of live `NarrativeIntroWidget`s, and `_G.__dwc_bridge.status().services`, where chat, vitals and fed_reflex report `running`.
- **`boot_and_join` against the running client (verified 19:21 local):** it detected "in world, services running" and did nothing (0 actions, 1.7 s). It wrote `logs/state/client_status.json`. The menu, sign-in, join and intro paths have been exercised only against the fake runner; **live cold boot UNVERIFIED** (main has the client on hold).
- **Steam state is readable without the UI:** `HKCU\Software\Valve\Steam\ActiveProcess.ActiveUser` is the logged-in account's 32-bit id. It reads 653927889 = 76561198614193617 − 76561197960265728 (bootymaxer), and 0 when nobody is logged in.
- **The client game log contains the world password, base64-encoded:** the `Browse:` and `LoadMap:` lines carry `?p=<b64>`. The tools redact `?p=...` and the plain password from everything they log, and never copy those lines.
- **Join failures that the log names:** `Connection Failed for reason [DuplicateChar]`, which a fast rejoin after a crash can hit while the server still holds the old connection (so boot retries with a 30/60/120 s backoff), and `PendingConnectionFailure ... Missing user ID` (not signed in).
- **Hang signals:**
  - The client's game log is chatty in the world: EOS lobby websocket lines every ~30 s.
  - The UE async log writer buffers, so after a game-thread stop the game log ends a few seconds *before* the Lua runner's last line. That happened at 17:53 (log 17:53:34, mod 17:53:54) and again at 18:27 UTC (game log 18:27:37, runner's last `inv_list` 18:27:42; then `inv_equip` and `disconnect` timed out). The 18:27 instance had no stack taken: the client was closed on purpose.
  - The only stack we have (`logs/client/stack_6400_175704.txt`) shows the GameThread in `NtWaitForSingleObject` beneath a UE4SS hook frame (frame 10). Its symbols are export-only.
  - `RemoveInvalidLockers ... invalid locks` precedes both hangs but appears 5–10 times per session, so it is not diagnostic.
  - The watchdog therefore treats as a hang: no runner answer while game log and client.log are both stale for 60 s with CPU < 0.05 core, or 3 probes in a row unanswered (about 90 s). It takes a `cdb -pv` stack before killing.
  - The UE4SS crash handler writes `ue4ss\crash_*.dmp` beside the client exe, then blocks. One was written at 19:08:42 local. The watchdog treats a new dump as a crash.
- **Search (search-before-building):**
  - Supervisors: NSSM and WinSW run programs as Windows services in session 0. Steam and the game client must run in the logged-on user's session, so a service can't drive them. Task Scheduler "at logon, interactive" is the idiomatic way to start a per-user supervisor (alternativeto.net/software/winsw, forum.syncthing.net/t/21512, discourse.nodered.org/t/10149). `start_client_watchdog.ps1 -Register` creates that task; it was not registered.
  - Steam `-applaunch <id> <args>` forwards the arguments to the game (developer.valvesoftware.com/wiki/Command_line_options_(Steam)). Nothing documents a second `-applaunch` while the game runs, so boot only launches when the process is absent.
  - Hang detection: the usual pattern is a heartbeat plus a sustained-CPU threshold with a grace period (thwack.solarwinds.com/discussion/32093, administrator.de/forum/161071). `Process.Responding` doesn't help: the client's only window is the `-log` console.
  - No game-client or bot watchdog fitting a UE4SS client was found.
  - Decision: **adapt** `tools/watchdog.ps1` (dump/heartbeat/cdb pattern), use the DWClient runner itself as the game-thread heartbeat, and **build** the thin boot state machine over the existing command files.
- **Teardown pause:** `join_server.lua` and `disconnect.lua` set `_G.DW_PAUSE` (commit 78ac755), and so far nothing clears it automatically. So boot runs `unpause.lua` once the pawn exists, the probe reports `paused`, the watchdog treats a pause that lingers more than 30 s in the world as degraded (it reruns boot_and_join), and the smoke test's `services` step fails while it is set.
- **First live fight (19:13:40-19:14:19 UTC, Shockbyte, commanded, force=true, lock-on off): INCOMPLETE, the client hung.**
  - Live state before it: Luis's stats edit had NOT reached the game: `BP_GetPowerLevel` 2, every skill level 1 (Agility 3), total 14. The only Kebbit nearby (73 m south) was inside a goblin camp (6 Goblin Runts, Aggressive, PL1, 120 HP; 2 Giant Rats, Aggressive, PL2, 200 HP), so the target was a lone Cow (NeutralUntilAttacked, PL2, 240 HP shown, 312 HP when read in the fight) 63 m north.
  - Worked: the arbiter suspended a stand-in task (`test_task`) for `combat:attack`; weapon choice from his own inventory (Bone Dagger, score 15.0, plus the Bronze Shield because the dagger is one-handed); equip by hotbar keys 6 and 8; `move.follow` of a creature by entity id (sprint, local planner) closed 63 m to 2.9-3.0 m; phase engage; one IA_PrimaryAction tap injected (3 frames).
  - Not verified: whether that swing played or hit (no stamina-spent or damage check had run yet), the Kebbit/Cow HP drop, loot, re-equip, resume.
  - **Bug found and fixed offline:** the cow's capsule keeps him about 3.0 m away centre to centre, beyond the fixed 2.2 m reach, so he stopped pressing. Reach and follow distance now grow with the target's `CapsuleComponent:GetScaledCapsuleRadius()` beyond 40 cm.
  - **Hang:** the game thread stopped about 19:14:19 (0 CPU, process alive). The game log's last line was `FlushAsyncLoading(9245): 1 QueuedPackages` at 19:14:11, after the first-ever dagger and shield equip and the first dagger swing. The cdb stack shows the GameThread waiting (`WaitForSingleObjectEx`) under a UE4SS hook frame (`logs/client/stack_8452_201705.txt`), identical to the 17:53 hang. Prime suspect (main): a synchronous asset load under NullRHI. Owned by the hang-investigation agent; combat retries wait for it. `BP_GetPowerLevel` (a Blueprint event) is now read at most every 10 s, as a precaution.
  - Also fixed: AI pawns have a `PlayerState` property that is a null object, so the never-attack-players check now requires a *valid* PlayerState.

## Client gathering (R2) (2026-10-25, client build 26162923, Shockbyte world; read-only probes `client_mod/commands/gather_probe.lua`, about 19:20 UTC)
Modules: `client_mod/scripts/gather.lua` (the job), `client_mod/scripts/gather_profiles.lua` (data), `sense.foliage` in `client_mod/scripts/sense.lua`. Commands: `gather_probe` (read-only), `gather_scan` (read-only), `gather_status`, `gather_stop`, `gather_ash2` (live). Offline: `lua client_mod/tests/test_gather.lua` (60 checks: profiles, the whole oak chain against a fake world, tool and tier failures, widening then nothing_in_range, unreachable, swings with no effect, an aim search, dead inputs, combat-reflex suspend and resume, inventory full, interact-collect, mining, ground pickups, pause, death, cancel, and the foliage maths over fake ISM components).
- **Why the client census could not see STANDING trees (VERIFIED live):**
  - On Claude's client every tree, sapling, bush, branch and ground stone is an instance of an `InteractableFoliageISMComponent`. There were 198 such components around him: `BP_InteractableFoliageISMC_Tree_C`, `_PickUps_C` and `_Sapling_C`.
  - Each component's `ActorClass` names the actor its instances turn into. Trees: `BP_BM_Tree_Oak_01_C`, `BP_FH_Tree_Oak_02_C`, `BP_Tree_Oak_01_C`, `BP_BM_Tree_Ash_0x_C`, `BP_FH_Tree_Ash_0x_C`, `BP_FH_Tree_Ash_Bare_0x_C` (dead ash), `BP_FH_Tree_Willow_0x_C`, `BP_DR_Tree_Maple_0x_C`, `BP_YewTree_0x_C`, and `BP_Cactus_*` (cacti also use the Tree ISMC). Pickups: `BP_Spawner_Stone_C`, `BP_Spawner_AshBranch_0x_C`, `BP_Spawner_Flax_C`, `BP_Spawner_Mushroom_C`, `BP_Spawner_Pumpkin*_C`, `BP_Spawner_Cabbage_C`, `BP_Spawner_Onion_C`, `BP_Spawner_Marrentil_C`, `BP_RedberryBush_C`, `BP_CadavaBush_C`, `BP_Weed_Desert_C`. Saplings: `BP_*Sapling_Ash_0x_C`.
  - Flags: Tree components have `bDamageable` true; PickUps components have `bInteractable` true; `FoliageType` was 2 on the pickups.
  - **The pawn's `NearbyFoliageConverterComponent`** (`BP_Components_NearbyFoliageConverter`) has `Range` **300 cm**, converts damageable and interactable foliage, and has `bStartEnabled` true. `GetEnabled()` reads **false on the client**, so the converting is done by the server.
  - So the server turns an instance into a real, replicated actor only within about 3 m of a player, or when a swing's trace converts it (`ConvertTracedFoliage` in the dump). A tree further from every player is foliage, and `FindAllOf` can't see it. That matches the bridge agent's "no standing trees" and the felled ash logs it did see.
- **Instance positions without a struct out-param (VERIFIED live):**
  - `ism:GetInstancesOverlappingSphere({X,Y,Z}, r_cm, true)` returns a **plain Lua table** of `RemoteUnrealParam` ints (use `:get()`), not a TArray (`ForEach` is nil). It is a bounds test, so filter by distance afterwards.
  - The reflected property `ism.PerInstanceSMData[i + 1].Transform` is an `FMatrix` of `FPlane`s: `WPlane.{X,Y,Z}` = the instance's local translation, `|XPlane|` = its scale. World position = component `K2_GetComponentLocation()` + yaw-rotated scaled translation (the tile components read rotation 0, scale 1).
  - Example: component at (126, 1890, -126) m, instance 7 local (-97.87, 12.49, 94.11) m → oak at (28.1, 1902.5, -31.9) m, 24 m from Claude, on the ground.
  - A zero-scale instance is treated as hidden (felled or converted). **UNVERIFIED** whether the client hides a converted instance that way.
  - `GetInstanceTransform` (an `FTransform&` out param) was not needed, so it was not called.
  - Cost: the whole 198-component pass with the sphere query took 33 ms on the game thread; the full probe took 55 ms.
- **`sense.foliage` live (VERIFIED, `gather_scan.lua`, about 19:36 UTC):** Ash Trees at 29.7-39 m and an Oak Tree at 38.9 m, found in 14-17 ms.
  - Name, gate and HP come from the actor class's default object: `cls:GetCDO()` → `DisplayName`, `DamageModifiersWhenTree` → Hatchet tier 1 (ash) / 3 (oak), `HealthComponent.MaxHealth` 160 / 220. These match the server census.
  - Pickup spawner CDOs carry the placeholder name "DEFAULT DISPLAY NAME", so their name comes from the CDO's `ItemData` instead ("Stone").
  - The census caps trees and pickups separately, because ground stones are everywhere and crowded the trees out.
  - The census grew from about 50-90 ms to about 105 ms (40 m radius).
  - `StaticFindObject` (no load) shows `AM_Player_Axe_OnSpot_Woodcut1` and `BP_Player_Axe_Woodcut1_C` already in memory on the client, so a first swing needs no synchronous asset load (the suspected hang pattern).
- **Rocks are level actors, not foliage (VERIFIED):** `BP_OreNode_Stone_C_UAID_*` HP 75 and `BP_MiningRock_RuneEssence_Static_C_UAID_*` HP 60 (`DestructibleMiningRock`), plus `BP_RuneEssenceGeyser_B_C_*` (`OreNode`, no HP). All replicate at 21-27 m. Felled-tree pieces (`BP_SplittableLog_Ash_C`, HP 80) were present 40-45 m away.
- **Pitfall:** `a.bIsStump` on a log or rock returns a `TrivialObject` (truthy; see "missing property is NOT nil"), so compare `== true`.
- **The gather job (offline-verified; live UNVERIFIED until the first supervised run):**
  - Phases: equip (the best `axe`/`pickaxe` he OWNS by `weapons_data` tier, hotbar key, verified from the held item) → scan → approach (`move.go_to` to a stand point at reach) → aim → swing → settle (step back and wait for the felled tree) → collect (magnet, then the interact key) → pick (pickups: walk up, wait for the detector, press interact).
  - **Scan order:** drops of the counted item near our sites; then pieces of OUR felled trees; then the nearest root (a converted actor or a foliage instance). The radius widens ×1.5 from 30 to 90 m.
  - **Aim:** `SetControlRotation` (the camera) plus a short `AddMovementInput` nudge, because the body turns only toward movement. The aim prior is the chop wedge 35° right of forward, from the server-puppet calibration. After 3 verified no-damage swings it tries the next offset (0, 20, -20), then another side.
  - **Swing:** IA_PrimaryAction through `combat._inject` / `combat.actions` (the same Enhanced Input path as fights). It uses the standard chop on every stage, because Overhead Chop needs Woodcutting 4 and Claude is level 1 (wiki).
  - **Verify:** stamina sampled 0.35 s after the press (the swing ran), and target HP after the damage point. A foliage target is adopted when a matching actor appears within 2 m. An undamaged adopted tree that reverts is chased as foliage again.
  - **Progress** = his inventory count of the item (bag + hotbar). For pickups with no known item id, the item is learned from the converted actor's `ItemData` or from the first inventory rise.
  - **Stumps are left by default:** chopping a stump stops the tree regrowing (wiki Woodcutting), and this is the group's world. Use `stumps=true` to take them.
  - Arbiter level `task`, lease 5 s. When suspended it does no input; on resume it re-checks the tool and rescans. Suspended time does not count toward the timeout.
- **Search (search-before-building):**
  - mineflayer-collectblock (src/CollectBlock.ts: nearest target first, `bot.tool.equipForBlock` with requireHarvest, drops within 0.5 blocks become new targets, a 10-tick wait for drops, `GoalFollow` to collect, cancel = stop the pathfinder).
  - Baritone MineProcess (counts the inventory each tick and stops at `desiredQuantity`; blacklists the closest location when a path fails; rescans; cancels when nothing is known).
  - The RuneLite/Microbot woodcutting search found nothing directly reusable: only the RuneLite WoodcuttingPlugin API (statistics, not automation).
  - Epic docs for `GetInstancesOverlappingSphere` (returns indices, bounds based), UE-149109 and forum reports that it over-reports by bounds (hence the distance filter).
  - Dragonwilds wiki Woodcutting / Overhead Chop: tier per tree, Overhead Chop at level 4 does about 10% damage to standing trees, stumps regrow in 72 h unless cut.
  - Nothing on Dragonwilds' melee aim assist (`MaximumAngleAimAssist` 45, camera-based); whether it helps against resources is a live question.
  - Decision: **adapt** (the collectblock / Baritone loop shapes, the legacy server profiles and chain) and **build** the thin client loop over move/inventory/combat/arbiter.
- **First live runs (2026-10-25, about 19:36-19:37 UTC, Shockbyte):**
  - `gather_ash2` answered at once with `wrong_tool` / `no_tool`, "I need a logging axe for ash and I don't have one." This was correct: after the 19:14 cow-fight death his axe, pickaxe, dagger, shield and torch were in a gravestone. Inventory: armour, food, drink, bolts. Nothing moved and the pawn was not taken.
  - `gather_stones2` (ground stones, interact key):
    - The arbiter granted `gather:stone` (task). The foliage scan picked a Stone pickup at 23.1 m (`fol:BP_InteractableFoliageISMC_PickUps_C_10:112`).
    - `move.go_to` failed `unreachable` / `no_route`: the local planner found only drop edges ("walls everywhere") from the lodestone-pad island. Gather blacklisted that stone and moved on to the next one at 12.7 m, as designed.
    - **The client then hung** (last mod line 19:37:01, move's local plan #3). The watchdog took a stack (`logs/client/hang_9728_20261025_203801.txt`), killed the client at 19:38:06 and rebooted it, back in the world at 19:38:59.
    - No interact press, swing or equip had happened. Gather was only polling `move.status`, `FindAllOf` and `inventory.list` (1 Hz) while move.lua planned. That run had `t.MaxFPS=30`.
  - Still **UNVERIFIED live**: a swing's hit on a tree, the felled chain on the client, magnet or interact collection, and the inventory delta.

## Traversal learning (R2) (2026-10-25, 19:24-19:45 UTC, client build 26162923, Shockbyte world, read-only)
Module: `client_mod/scripts/traverse_learn.lua` (task R2.12; design `docs/research/2026-10-25-traversal.md` 3.5). Commands: `client_mod/commands/learn_start.lua`, `learn_status.lua`, `learn_stop.lua`, `learn_rebuild.lua`. Offline test: `lua client_mod/tests/test_traverse_learn.lua <empty_dir>` (39 checks).
- **What it is.** A read-only recorder: one `LoopInGameThreadWithDelay(1)` loop, about 120 Hz live.
  - It never moves the pawn or presses input.
  - Per frame and per tracked pawn (every other player via PlayerState `PawnPrivate`, plus Claude himself), it reads `CharacterMovement.MovementMode`, `.Velocity`, `ReplicatedJumpCurrentCount` (and `JumpCurrentCount` on the local pawn) and `K2_GetActorLocation`.
  - An event opens on falling (mode 3) or a jump-count change, and closes on landing.
  - It honours `_G.DW_PAUSE` and an invalid controller/pawn: verified offline, no UObject reads while paused.
- **Proxy reads VERIFIED live.** On Luis's simulated proxy, `CharacterMovement.MovementMode` reads 3 in the air and 1 on the ground, and `ReplicatedJumpCurrentCount` reads 1 then 2 within the jump.
  - Luis's double jump: the count went 1→2 at **0.31-0.33 s** after take-off, with vz 201→670 cm/s (second impulse). That matches move.lua's 0.35 s second Jump.
  - Measured double-jump rise (take-off to the dash at the apex) **2.7-3.3 m**, sprinting at 6.0-6.8 m/s. These are NOT ledges: the "landing" was the dash entry (MOVE_Custom, below).
  - So a rise of 2.5-3.3 m is a double jump, not Windstep. The recorder calls it Windstep only on a Windstep cast since the last landing, a rise > 2.5 m on a single jump, or a rise > 4.5 m.
- **`ReplicatedJumpCurrentCount` is STALE on proxies after landing.** It stayed 2 through Luis's walk-off drop 1 s after a double jump (19:40:48), so that drop was first misclassified as double_jump. It reads 0 again at other times.
  - **Rule:** only a *change* from the grounded baseline is a jump signal, never the absolute value.
  - Fixed, with the fake leader in the test now keeping a stale count.
- **The 9-12 m/s "walk-off take-off speeds" were the air dash** (MOVE_Custom, mis-read as ground), not proxy smoothing. Explained below.
- **MOVE_Custom (6) is the AIR DASH. VERIFIED live (19:44:14).** Dominion's `ECustomMovementMode` has a single value, `CMOVE_Dash = 1` (dump `Dominion_enums.hpp:1055`).
  - Luis's proxy went mode 3 → **6** at the apex of his double jump (vz ~0, Z flat), the dash carried him ~5 m in mode 6, then mode 3 again until landing.
  - He travels this way constantly: a double jump (second jump at 0.31-0.33 s) plus a dash every ~12 m.
  - The first recorder version treated mode 6 as grounded and split each flight into "double_jump up" + "drop down". The 9-12 m/s "walk-off speeds" were the dash velocity.
  - **Rule:** modes 3, 5 and 6 are airborne. Entering mode 6 is recorded as a dash (`custom[]`, `dashes[]`), and the event's move becomes `air_dash`.
  - The live raw events were repaired: 16 split pairs merged, marked `repaired: split_by_custom_mode`; backup `traversal_events.jsonl.bak_before_custom_fix`. The store was rebuilt.
  - The evade multicast is **not** how the air dash replicates. Whether it fires for a ground evade is still unseen.
- **Multicast hooks** `PlayerEvadeComponent:Multicast_StartEvade`, `PlayerMagicComponent:Multicast_SendPayloadForSpellCasting` and `DominionMovementComponent:Multicast_ApplyFallDamage` register on the client (`ok=true`). No hit was seen yet (hook_hits 0). **Windstep detection on live data is UNVERIFIED** (offline only). Hooks that fail at the main menu are retried from the tick every 10 s.
- **Walkable-terrain filter (after the dash finding):** every flight ≥ 1.5 m within **80 m of Claude** gets downward probes under its line, every ~0.5 m, max 12, none within 0.7 m of the landing.
  - With no gap and every segment |dz| ≤ 45 cm + 0.3 × its length, the flight was over walkable ground. It stays a raw event (`why: walkable_terrain`), not a link. This drops Luis's dash-hops over rolling ground.
  - Flights farther than 80 m from Claude are not probed (client collision streams around Claude, so "no floor" there may just be unloaded). A far flat flight stays a hop, and a far up/down flight is kept with `gap_probe.unprobed`.
- **Live store after the repair** (data/skills/shockbyte/traversal_links.json, 10 links; feet-level endpoints, metres):
  - Luis's drops L1 (3.05 m at (114.4,1838.2)) and L4 (5.7 m at (223.8,1797.9)).
  - 7 Luis `air_dash` links (dz -3.1..+1.3 m over 11.8-14.8 m). They predate the walkable filter and are `usable=false` for Claude (`needs:AirDash`).
  - **L10 = Claude's own sprint_jump up 1.54 m, `verified`, source self** (local-planner crossing at (442.7,1800.3)→(444.3,1804.5)).
  - The first double-jump demos (3.03 m and 2.53 m ledges) turned out to be double jump + dash flights that the repair merged.
  - Claude's own step-ups of 0.61-0.63 m were seen and correctly not made links (self threshold 1.0 m).
- **Live cost:** about 120 Hz loop. A trace count of 59 over ~60 events (traces happen only after a landing). No `last_error` after the `try()` fix (an early `tonumber()` of a failed read raised once per tick until then).
- **Classification:**
  - shape: up (dz ≥ 0.6 m), down (dz ≤ -1.5 m), gap (a flat flight ≥ 1.5 m with downward traces under it finding no floor within 1 m below the lower end), else flat (a hop: raw event only, no link);
  - move: drop | jump | sprint_jump (take-off > 5.2 m/s) | double_jump | air_dash (MOVE_Custom mid-air, an evade multicast mid-air, or a horizontal speed rise > 3 m/s in 0.2 s) | windstep. The easiest move seen to cross a link is what it needs.
- **Clustering:** leader clustering. A new event merges into a link when from is within 1.5 m, to within 2.0 m and the heading is within 25°. Endpoints are a member-weighted running mean, and `n_seen++`. Self crossings within 2 m of both endpoints mark the link **verified** (`n_ok++`) and never move it. `record_attempt` failures 3 times in a row → `disabled`.
- **Traces hit attached gear:** `LineTraceSingle`'s bIgnoreSelf skips only the context pawn, not its attached armour or held actors (locomotion agent). Gap probes therefore skip points within 1 m of the landing, where the jumper stands.
- **Files:**
  - raw events `logs/state/worlds/<world>/traversal_events.jsonl` (one line per airborne event, with up to 120 airborne samples `[dt,x,y,z(capsule),mode,jc,vz]` for replay fixtures);
  - links `data/skills/<world>/traversal_links.json` (git-tracked; this module is the single writer; `rebuild` re-clusters from raw events).
  - World id: `DW_WORLD_GUID` (global or env), else `client_io/world_guid.txt`, else `shockbyte`.
- **move.lua consumes it (locomotion agent, move.lua v6):** `best_link(me, goal, {env, max_detour=3})` at the unreachable give-up, then `record_attempt`. A nil result with `needs:X` becomes the unreachable reason. Not yet in localplan A* edges.
- **Search (search-before-building, 2026-10-25):**
  - Queries on learning off-mesh/jump links from player trajectories, CS bot learn modes, trajectory/flight-phase segmentation and online leader clustering.
  - **No source turns recorded human jumps into navmesh links.** Unity, UE and Recast generate links from geometry: docs.unity3d.com nav-BuildingOffMeshLinksAutomatically; dev.epicgames.com automatic-navigation-link-generation; Utrecht thesis studenttheses.uu.nl/handle/20.500.12932/22818.
  - CS bots use hand-placed jump hints (developer.valvesoftware.com Nav_Mesh_Editing; RealBot learns without human guidance).
  - The closest prior art is a patent family building route links from aggregated player telemetry, dropping rarely used links (USPTO 10406437 / 11235241). That supports our `n_seen`-based confidence.
  - Phase segmentation in the flight-trajectory literature is rule- or HMM-based on altitude and vertical rate (arxiv.org/abs/2203.09033; TU Delft JOAS HMM flight phases). We adapt the rule-based form, since the engine gives us the movement mode directly.
  - Leader (threshold) clustering with member-weighted merges is the standard online pattern (arxiv.org/abs/1506.07208; arxiv.org/abs/2006.01117).
  - Decision: **adapt** (off-mesh link model, rule-based phase segmentation, leader clustering) and **build** the thin recorder. No library was needed.

## Client hang (R2): GameThread deadlock in ULightFlickeringWorldSubSystem (2026-10-25, client build 26162923; diagnosed from cdb stacks + static reading of the shipped exe, read-only)
- **Symptom:** six hangs between 17:53 and 19:38 UTC (17:53:54, 18:27:42, 19:14:19, 19:26:35, about 19:30:07, 19:37:01). The process stays alive at about 0 CPU; the GameThread sits in `NtWaitForSingleObject` and every worker is idle.
  - All five GameThread stacks taken (`logs/client/stack_6400_175704.txt`, `stack_8452_201705.txt` + `stack_all_8452_201730.txt`, `stack_9064_202831.txt`, `hang_9712_20261025_203310.txt`, `hang_9728_20261025_203801.txt`) are identical return address for return address.
  - The last game-log line varies (FlushAsyncLoading, EOS lobby, QuickAccessBar), so it is not the cause.
- **Method:** the exe has export-only symbols and no PDB (Jagex and Epic publish none for a shipping game). Live module base 0x7ff710650000 vs preferred base 0x140000000.
  - Frames were mapped by disassembling the on-disk image with `cdb -z <exe>` (`ub`/`uf` at the image addresses).
  - Callee identities came from argument patterns (ENamedThreads values, vtable slots), string xrefs, and `.rdata` vtable/name neighbourhoods (scratch scripts: PE pointer search, lea/call xref scan).
- **Mapped GameThread stack, outermost first:**
  1. `FEngineLoop::Tick` → `GEngine->Tick` (vtable +0x2F0) → game engine Tick wrapper → `UGameEngine::Tick` (0x143fe4020, the function UE4SS's EngineTick detour wraps; UE4SS is only the pass-through frame) → `UWorld::Tick(LEVELTICK_All=2, dt)` (0x1441be850).
  2. `RunTickGroup(TG_DuringPhysics=2, bBlock=false)` → `FTaskGraphInterface::ProcessThreadUntilIdle(GameThread=1)` → GameThread named-queue task → `FTickFunctionTask::DoTask` → `ExecuteTick` (vtable slot 3, tail call).
  3. **`ULightFlickeringWorldSubSystem::Tick`** (0x1468f8ab0). Identity:
     - its `this` fields start at 0x68 = sizeof(UJgxTickableWorldSubsystem); the class is 0x2D0;
     - the adjacent `.rdata` holds the `LightFlickeringWorldSubSystem` name and its native function table (AddLightFlickering, RemoveLightFlickering, UpdateLightBaseIntensity).
  4. 0x1468f9970: `if (PendingTask /*this+0x1A8*/) FTaskGraphInterface::Get().WaitUntilTasksComplete({PendingTask}, AnyThread)` (vtable +0x60) → task-system wait → `FEvent::Wait(MAX_uint32)`.
- **What the subsystem does each frame:**
  - It waits for last frame's task, swaps its three result sets (this+0x68/0x108/0x1A8 ↔ +0x1E0..) and reads the first local player's view location.
  - It launches `FFunctionGraphTask::CreateAndDispatchWhenReady(lambda, ..., ENamedThreads 0x2FF = AnyBackgroundThreadNormalTask)` and stores it at this+0x1A8.
  - The background body (0x1468f6660) accumulates time, computes flicker for the registered lights, then **dispatches a follow-up task to `ENamedThreads::GameThread` (1) and calls `MyCompletionGraphEvent->DontCompleteUntil(thatTask)`**.
- **Root cause:** the background task's completion depends on a GameThread task. Next frame, the subsystem waits for it from inside a GameThread tick task.
  - The GameThread is already "processing tasks" (inside ProcessThreadUntilIdle), so `WaitUntilTasksComplete` takes the stall-on-event branch instead of draining the GameThread queue.
  - Whenever the background task plus its GameThread follow-up has not finished by the next frame's TG_DuringPhysics tick, the GameThread waits forever for work only it can run. That is a self-deadlock and a timing race.
- **Why our client hits it** (a normal player probably never does):
  - **about 115 fps** (GameFrameRateLimit=120, NullRHI makes frames cheap), so the window is about 8 ms;
  - only **2 background workers** (4 vCPU) at below-normal priority, shared with item and asset streaming. This explains the correlation with equips, pickups, eats and new meshes;
  - CPU contention from the dev server and brain on the same VM;
  - heavy GameThread Lua bursts (hang 6: LineTrace bursts, no asset load).
- **Ruled out:** a NullRHI render fence or flush (the render thread is idle in its task loop, and no RHI wait is on the stack); UE4SS (pass-through tick detour only; the wait is engine plus game code); the async-loading thread (idle).
- **Fix (live 19:40 UTC, pid 4488): `client_mod/scripts/tickguard.lua`.**
  - It writes the reflected `UJgxTickableWorldSubsystem.PrimarySubsystemTick.TickInterval` (FTickFunction at +0x30, float at +0x3C) = **3600 s** on every live `LightFlickeringWorldSubSystem`, then reads it back.
  - The tick then runs about once an hour, so the wait always finds the previous task long done.
  - Effect: client-local light-intensity animation only, which a -nullrhi client never draws. Server and players are unaffected. FTickTaskLevel re-reads TickInterval every frame, so no re-registration is needed.
  - Supervised as `client_bridge.SERVICES` "tickguard" (healthy = every live instance has the interval; re-applied within 10 s on each new world, from the next bridge start).
  - Commands: `tickguard_apply.lua`, `tickguard_status.lua`. Read-back verified: 0.0 → 3600.0.
  - The guard table (`M.GUARDS`) is generic: add a row for any other tick function found to deadlock.
- **Defence in depth: 30 fps cap.**
  - `t.MaxFPS=30` in Engine.ini `[SystemSettings]` is **overridden** by the game: it applies `DominionUserSettings.GameFrameRateLimit` (t.MaxFPS read back 120 at runtime).
  - Effective: `GameFrameRateLimit/FrontendFrameRateLimit/FrameRateLimit=30` in `Saved/Config/Windows/GameUserSettings.ini` (next boot), or at runtime `client_mod/commands/fps_cap.lua` (game settings object: SetFrameRateLimit + ApplyNonResolutionSettings).
  - Measured: 28–29 fps (was 99–116); client CPU 0.53 cores (was about 1.2). `fps_probe.lua` reads the limiter state.
  - Prefer the game's own user setting over `-ExecCmds` or an Engine.ini CVar, which the game's settings re-apply overwrites.
- **Not chosen:** WARP/D3D12 software rendering (it costs CPU and RAM and doesn't remove the race); `-onethread` (changes all task semantics, slow); more workers (`-foregroundworkers=` exists; it only narrows the race); patching the wait (binary patching not approved).
- **Watchdog:** the 5th hang was caught late because `GraceS=240` counts from process start. `tools/client_watchdog.ps1` now ends the grace once a probe has seen this pid in L_World (`$script:inWorldPid`).
- **Search (search-before-building):**
  - "UE5 WaitUntilTaskCompletes game thread deadlock DontCompleteUntil", "nullrhi client hang uncapped framerate", "UE4SS engine tick hook deadlock": nothing specific to this pattern.
  - Epic's Tasks docs say waiting "should be avoided" and that busy-waiting "caused deadlocks regularly"; UE 5.5 oversubscription only wakes extra workers, so it cannot help a GameThread-only dependency (dev.epicgames.com/documentation/en-us/unreal-engine/tasks-systems-in-unreal-engine).
  - The FTaskGraphInterface API docs: WaitUntilTaskCompletes "requests that a named thread, which must be this thread, run until a task is complete" (dev.epicgames.com/documentation/unreal-engine/API/Runtime/Core/FTaskGraphInterface).
  - t.MaxFPS caps by sleeping the GameThread (dev.to/feed/adbhut).
  - Decision: **reuse** the engine's own tick-interval mechanism and the game's frame limiter; build only the thin guard.
- **Open:** an hour-long soak is needed to confirm no hang (the base rate was 1 per 5–40 min). An interval tick still fires once an hour; if a hang ever recurs with this stack, raise the interval or add a guard row.
- **FIRST REAL FIGHT WON, VISUALLY VERIFIED (2026-10-25, 19:50:19-19:51:14 UTC, Shockbyte, after the hang fix; Luis watched from GFN: "he is blocking correctly and using some combos - proud of him").**
  - Setup: no Kebbit or Cow within 80 m of the plateau, so the target was a lone **Goblin Runt** (`BP_AI_RuntGoblin_Character_C`, Aggressive, PL1, 156 HP), 34-42 m away; the next hostiles were 64 m or more away. Commanded `attack` **without force**: the fight-or-flight check rated it winnable (u_fight 0.79 at the start, rising to 0.98), Claude PL2, level-1 skills, 100 HP.
  - Equip from his own inventory: Bone Dagger (hotbar key 6) + Bronze Shield (key 8), in under 1 s.
  - Approach: `move.follow` of the creature by entity id, 26 s (sprint plus local planner up the slope), reach 2.2 m.
  - Engage: **17 IA_PrimaryAction taps** injected; **10 of them verified by stamina spent** (the others fell during blocks, or the stamina had already regenerated). Luis saw **combos**: the 0.5 s input buffer turns a jittered cadence (the weapon's own input-window timing, 0.77 s + 40-200 ms) into chains.
  - **Telegraph hook verified:** `AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies` fires on Claude's client for every goblin attack (10 events in the fight). Each one triggered **a block** (IA_SecondaryAction held about 1.2 s, after a 150-300 ms reaction delay): 6 blocks, stamina 56 → 29 at its lowest, **Claude took 0 HP damage** (hp_frac 1.0 throughout).
  - Goblin HP (replicated `GetAuthoritativeHealth`, read at about 2.5 s intervals): 156 → 142 → 112 → 98 → 68 → 10 → 0. Killed at +49 s.
  - Loot: one IA_Interact press at the kill spot (19:51:09); the targeted world item vanished (looted 1); the bag afterwards held GoblinPack x2 and Bone Bolts x3 among others (the before/after delta was not captured).
  - **Bugs found live, fixed offline (80 checks pass):**
    - (1) **Our hits never matched**: 0 of the damage multicasts on the goblin named Claude's pawn as `Instigator`. Now the pawn or the PlayerController counts, and every damage event on the target is kept in `combat_status.on_target` (instigator and source class) to settle this on the next fight.
    - (2) **Re-equip skipped**: a two-handed tool is reported in the LEFT hand only (`held.right` nil, `left` = Mithril Logging Axe), so `prev_right` was nil. Now the main held item (right, else left) is restored. The axe was re-equipped by hand afterwards (hotbar key 4; held left = axe).
- **Reflex + arbiter verified live (19:43:49-19:44:04 UTC, while Luis led Claude up the hill):** the guard saw a **Giant Rat** (Aggressive, PL2, 260 HP) at 2.3 m (`hostile_near`). It suspended the bridge's unregistered `go_to` (adopted as `move:go_to`), rated the fight `losing` (equal power level, 260 HP), **fled toward Zezima**, ended safe after about 14 s, released, and the arbiter **resumed the go_to**.
- **Arbiter bug (live, 20:05-20:07 UTC), fixed:** main's manual `go_to` drove move.lua directly; the arbiter adopted it as the implicit owner `move:go_to` (when the reflex suspended it). After the move ended, the owner was never released, so `gather` was refused `pawn_busy` while Claude stood still. Fix: an implicit owner is released as soon as `move.status()` is idle, has a 30 s lease renewed while its move runs, and a refusal returns the owner's name, level, age and move status. gather's canned "busy with something more important" line is replaced by structured data (`why`, `owner`, `busy_with`, `busy_move`).

### Defence, perks and held-item actions (2026-10-25, read live, read-only, client build 26162923)
- **Parry needs a perk Claude lacks.** The block actions' CDOs (`/Game/Gameplay/Character/Player/Abilities/Block/PA_Block_*`):
  - Shield (`PA_Block_Shield_Kite_Iron_C`, also the Bronze Shield's): `bCanParry` true, `SkillPerkRequiredToParry` = **`PerkV2_Attack_Parry`**, Block/Parry stamina 10, `ParryRefundMultiplier` 5, `bRequiresHolding` true.
  - Dagger (`PA_Block_Dagger_C`): can parry with the same perk, 35 stamina, refund ×1.4.
  - Pickaxe (`PA_Block_PickAxe_C`): `bCanParry` false, 20 stamina.
  - `SkillPerkComponent:IsPerkUnlocked(PerkV2_Attack_Parry)` = **false** for Claude. Community sources put Parry at Attack 5 (gamever.io "Parry at 5, Specials at 8, Tempest Shield at 11"; dragonwilds.runescape.wiki/w/Melee; esports.gg skills list).
  - `PlayerBlockingComponent`: `ParryWindowLength` 100 (ms), `ParryDamageMitigationPercentage` 100, `MinimumBlockDuration` 0.75, `ParryAnims` = `DA_Player_ParryAnims`. Parry montages: `AM_PlayerM_Shield_Parry`, `AM_PlayerM_Dagger_Parry`, ...
- **Weapon specials need a perk too:** `PA_Attack_Dagger_Special_C.RequiredPerk` = **`PerkV2_Attack_MeleeSpecialAttacks`**, not unlocked (wiki: Attack 8). The first Goblin fight's unverified presses included specials; combat now gates the special on the action's `RequiredPerk`.
- Evade: `PlayerActionPerformer.DefaultEvadeAction` = `PA_Evade_Default_C`, no RequiredPerk. Ping: `PlayerState:GetPingInMilliseconds()` ≈ 50 ms.
- **The game's own signals used for defence** (dump; hooks registered, live firing still to verify):
  - At the telegraph, `AiAttackComponent.CurrentAttack.AttackData` (`UAiAttackData`) gives `GetDamageTime()`, `GetLastDamageTime()`, `GetDuration()`, `AttackPropertyFlags` (`EAttackProperties`: Unblockable 1, Unparryable 2, Special 4, ComboFinisher 8, ForceBlast 16) and `Damage[]` {Time, Shape (`UDominionShape_*`), Force, DamageClass}.
  - The verdict on Claude's block: `PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack` / `...BlockedAttack`; `FBlockOutcome {Result EBlockResult, bParried, ParryRefund}`. The AI also has `PreemptParryWindowOpening(ParryWindowLength)`.
- **Held-item actions (live, `combat.held_actions`):** `UHeldEquipmentData.{Primary,Special,Secondary,PrimarySprint,PrimaryJump,PrimaryVisceral}ActionClass`. Each class's CDO (`UPlayerAction`) has `ActionName` (FText), `RequiredPerk` and `bRequiresHolding`. Mithril Pickaxe (held left, 2H): primary "Attack" (`PA_Attack_Pickaxe_C`), secondary "Block" (`PA_Block_PickAxe_C`, holding). These are offered to the model as styles (`attack.style`, `gather.style`, `use_action`); the model chooses, nothing is hard-coded per resource.
- **Design (search-before-building):** parry = an input inside a few-frame window before the hit, and input lag shrinks it (bugnet.io/blog/bug-reporting-for-games-with-parry-and-block-timing). Melee lag compensation splits the one-way latency off the wind-up (gamedev.net/forums/topic/634003). Dragonwilds: dodge cancels most animations; stamina regenerates only after 3 s without stamina actions (dragonwilds.runescape.wiki/w/Stamina). Nothing found on bots that learn parry timing, so built `client_mod/scripts/defense.lua`:
  - The press is sent at `T - 2L - window/2 + offset`. T is the attack data's damage time, replaced by an EMA of observed telegraph→verdict times; L is the one-way latency.
  - The offset adapts: blocked-not-parried means too early, so press later; hit means too late, so press earlier.
  - Too fast for a 150-300 ms reaction → plain block. Unblockable → dodge, or jump if the shape is low or a centred area attack. No stamina → retreat.
  - The policy comes from the model's `combat_orders`.

## Client crafting (R2) (2026-10-25, client build 26162923; reflection dump 26161880; task R2.19, design `docs/design/r2-crafting.md`)
Module `client_mod/scripts/crafting.lua`; offline tests `client_mod/tests/test_crafting.lua`; read-only probe `client_mod/commands/craft_probe.lua`; read-only capture of the UI call chain `client_mod/commands/craft_capture.lua` (writes `client_io/events/craft_capture.jsonl`).
- **The crafting UI has its own API object, like the inventory** (dump, Dominion.hpp:18170), the real player path for a bench:
  - `UCraftingUIAPI` {`CurrentStation` (UCraftingStationComponent), `StandbyStation`, `CurrentCraftRecipe`, `InventoryAPI`, `PlayerController`, `ProgressComponent`};
  - its handlers: `ShowCraftingUI(Station, EWidgetType)`, `ToggleCraftingUIVisibility`, `HideCraftingUI(EWidgetType)`, `SelectRecipe(URecipeData*)`, `SelectCraftingAmount(int)`, **`SendCraftRequest(int Amount)`**, `SendRepairRequest`, `SelectRepairItem`.
  - EWidgetType: Crafting 6, Processing 15, WorldInventory 26, Container 33.
  - **[UNVERIFIED until craft_capture runs]:** `SendCraftRequest` → `InventoryController:CraftRecipe` → `Server_CraftRecipe` with the game's own BonusCount, XP multipliers and `GetLinkedInventories`.
- **Processing stations have `UProcessingStationUIAPI`** (Dominion.hpp:31161):
  - fields: `ProcessingStationComponent`, `StationIngredientsInventory`, `StationFuelInventory`, `ValidIngredients`;
  - handlers: `ToggleProcessingStationStarted()` (the start button), `SetCurrentProcessingStation(Comp, IngredientsInv, FuelInv)`, `UnsetCurrentProcessingStation`, `ClearProcessingStation(PC)`.
  - Items go in through the inventory UI's external-slot handlers (`UInventoryUIAPI`, Dominion.hpp:25045): `HandleSplitToExternalSlot(FromSlot, FromSlotType, Amount, ToSlot, OutsideTargetInventory)`, `HandleDragAndDropToExternal`, `HandleExternalQuickTransfer(Slot, OutsideSourceInventory)`, `HandleDragAndDropFromExternal`.
- **`UProcessingStationComponent`** (Dominion.hpp:30943), live-readable state:
  - `bStationRunning`, `bReadyToProcess`, `RemainingProcessingTime`, `RemainingFuelTime`, `CurrentRecipe`, `LastValidRecipe`;
  - inventories `Resources`, `Fuel`, `OutputInventory`; `bStoreOutput`, `StorageType`;
  - `AcceptedResources`, `RecipesCache`, `ProcessInstigator` (FDomCharacterGuid).
  - `UCraftingStationComponent`: `ValidRecipes`, `DisplayName`, `bIsVendor`, `bHaveRepairOption`.
- **Unlocks are item/actor discoveries, not skill levels.** `FProgressionBundleRow.UnlockQueryString` uses only `ITEMS[...]` (815 recipes), `ACTORS[...]` (252), `ALL [entitlement]` (10) and `GOLD[agility courses]` (1). So holding an item and being near a station unlocks most recipes. The catalog's Lua now carries them as `uq`, and the planner shows them with station names (e.g. `ALL ITEMS[ Iron Ore ] AND ALL ACTORS[ Furnace ]`).
- **Claude's own unlocks** are read from `pc.ProgressComponent.RecipesUnlocked` (the TSet, as on the server). `UProgressComponent:IsRecipeUnlocked(URecipeData*)` exists too.
- **Server verdict:** `InventoryController:Client_OnCraftingResultHandler(ECraftingResult, Recipe, Count)` is a Client RPC. A read-only post-hook on Claude's client gets the result code; the codes map to speech in `crafting.RESULTS`, and an unknown code becomes `craft_failed`.

## Claude's stats raised (2026-10-25 21:19 local, client build 26162923)
- Luis's edited character file (`edited.json`, max XP, 48 selected spells) **loaded unchanged on the dev server**, which had never seen Claude (total level 1076). So the file format and our login path are fine.
- On Shockbyte the server keeps its own per-character copy (CachedCharacterStates), keyed by character GUID. That copy overrides the uploaded file for a character it has seen before (DISCOVERIES "Raising Claude's stats…").
- **Fix that worked:** give the edited file a **fresh `meta_data.char_guid`** (`A8642C53AD2F422CA02FD23615387E10`, with worlds_playtime cleared), keeping the name "Claude".
  - Shockbyte has no copy for the new GUID, so it took the file: **total level 1076 live on Shockbyte** (Woodcutting/Attack/Construction/Farming/Runecrafting/Agility 99, Magic 89, Mining 93, Ranged 93, Artisan 84, Cooking 73, Fishing 50).
  - The old level-1 GUID `D06CFBE3…` stays unused in the world save.
- Files: `edited.json` / `edited_newguid.json` are gitignored. Backups are in C:\GameServers\backups\claude_before_devtest_*, claude_after_devtest_*.
- Power level read 2.0 right after join (a gear-based value?); recheck.
- **Live read-only probe (20:20 UTC, Shockbyte, Claude at the church respawn; `craft_probe.lua`):**
  - `CraftingUIAPI`, `ProcessingStationUIAPI` and `InventoryUIAPI` each exist once on the headless client.
  - Claude's `RecipesUnlocked` = **46** recipes, still 46 after Luis's stat edit (total level 1076): unlocks don't come from skill levels. They include the Community Cape (0 inputs, Crafting Table), the Compost Bucket (5 Ash Logs), the Ash Rod, the Whetstone, the Magic Focus, potions, teas, rune-altar runes and the skillcapes (Mystic Forge).
  - The census typed a **Crafting Table** (`BP_Crafting_StartingBench_C`, 75 recipes at that station type, 6 of them unlocked for Claude) at 72 m, [107, 1845, -32].
  - The bridge lists `craft`, `recipes`, `craft_plan` and `stations` in its capabilities.
- **FIRST REAL CRAFT through the UI path (verified 20:22:17 UTC, Shockbyte, debug-channel `craft {recipe: RECIPE_Armour_T0_Cape_Community}`):**
  - Claude walked about 18 m to the Crafting Table and pressed E once; the game opened its menu (`CraftingUIAPI.CurrentStation` became that bench).
  - He ran `CraftingUIAPI:SelectRecipe` + `SendCraftRequest(1)`, and the server answered **`Client_OnCraftingResultHandler(0 = Success, RECIPE_Armour_T0_Cape_Community, 1)`**.
  - The **Community Cape** arrived in his bag (slot 1). He closed the menu with `HideCraftingUI(6)`.
  - Result: `{ok, recipe_chosen, gained 1, result_code 0, detail "I made 1 Community Cape at the Crafting Table."}`.
  - No `Server_*` call was made by us.
- **Capture lesson (`craft_capture.lua`): a UE4SS `RegisterHook` on a `Server_*` RPC does NOT fire on the SENDING client.**
  - The capture logged only SelectRecipe, SendCraftRequest, Client_OnCraftingResultHandler and HideCraftingUI.
  - Not logged: `Server_CraftRecipe`, `InventoryController:CraftRecipe`, `PlayerInteractionManager:Server_RequestInteraction` (the E press that did open the menu), `ShowCraftingUI` or `Client_ToggleCraftingMenu`. All of them must have run.
  - Explanation: a hook runs when the UFunction body executes locally. On a client, a Server RPC is only forwarded (`CallRemoteFunction`), and functions called C++-to-C++ (not through ProcessEvent) bypass the hook. Client RPCs do execute on the client, so they are hooked.
  - So the client cannot prove the internal chain with hooks. The proof that the UI handler is the real path is the outcome: the server's own verdict (code 0) plus the inventory gain.
  - **We never call CraftRecipe or Server_CraftRecipe**, so the reviewer's fallback conditions (a)-(d) never come up.

## Client spells (R2) (2026-10-25, client build 26162923; reflection dump 26161880; task R2.20, design `docs/design/client-spells.md`)
Module `client_mod/scripts/spells.lua` (tools `spells`, `cast`). Read-only probes: `client_mod/commands/spell_probe.lua`, `spell_inputs.lua`, `spell_baseline.lua`, `spell_slices.lua`. Offline: `lua client_mod/tests/test_spells.lua` (65 checks).

**Where things live on the client (read live, 20:05 UTC and after the 21:19 local (20:19 UTC) character swap):**
- **Unlocked spells:** `pc.ProgressComponent.SpellsUnlocked` (TSet `ForEach(a, b)`). Before the swap there was 1 (Windstep); after it, 38.
- **The wheel:** `pc.SpellcastingComponent.SelectedSpells`, a flat array of `NumSpellRadials` 4 × `NumSpellSlotsPerRadial` 12 = 48. Page p, key k is index (p-1)·12 + (k-1).
  - `GetCurrentlySelectedSpellData()` (BlueprintPure) works.
  - `MaxDistanceFromCameraToPlaceSpell` is 1500 cm.
- **Static spell data, readable from Lua on the client:** `UtilitySpellData.SpellDisplayName`, `CastType` (0 Instant, 1 Placed, 2 Aimed, 3 AllowMovementThenCastInstant), `CooldownDuration`, `bAllowCastingWhileFalling`, `SpecialRequirementsText` (e.g. "Logging Axe", "Cast on a tree").
  - Costs: `Modules.Modules[].Module` → `SpellModule_CostItems.ItemsCostInfo[] {ItemData, Count}`. `ItemData.Name` gives "Air Rune".
  - `OwningPerk.PerkDescription` is the game's own description, e.g. "Summons the power of Air Magic to Jump higher and Descend slower.".
  - `OwningPerk.PerkUnlockInfo {AssociatedSkill, RequiredSkillLevel}`. Windstep = Agility 5, Summon Shelter = Construction 20.
  - `SpellIcon` (soft pointer: `GetObjectID():GetAssetPathName()`) is the same texture the wheel slice shows.
- **UI truth per slot:** `HUDUISubsystem.SpellcastingAPI:GetSpellDisplayInfo(slot)` (BlueprintPure, struct return → Lua table). Read for slot 0: `SpellName`, `DescriptionText`, `bIsUnlocked`, `CooldownDuration`. Nested `SpellItemCost[]` entries came back unreadable from the table form, so costs are read from the spell data instead.
- **Pawn:**
  - `PlayerUtilityMagicComponent`: `CastingTag` `Player.Status.Casting.UtilitySpell`, `SpellBeingPreparedOrCast.SpellBeingPreparedOrCastData`, `LastCastTimeBySpellData` (TMap, empty before any cast), `OurSpellActors`.
  - `pawn.WindstepTag` = `Player.Spell.WindStep`.
  - `GameplayEffectsComponent.ReplicatedInstances` / `NonReplicatedInstances` were empty at rest.
  - Server clock: `GameStateBase:GetServerWorldTimeSeconds()` (58109.8 at 20:12).
  - **UNVERIFIED:** that `LastCastTimeBySpellData` values use that clock. Check it after the first cast.
- **Runes:** they are ordinary inventory items (`ITEM_Rune_<Element>`) in `pc.InventoryComponent.ItemSlots` (the runes page). Luis dropped Air 821 / Astral 5452 / ... at about 20:00. After that swap the inventory was empty, so every spell answers `not_enough_resources`.

**Key path (mapping contexts read live; key names from `EnhancedActionKeyMapping.Key.KeyName`):**

| Context | Mappings |
|---|---|
| `IMC_GameplayUI` | Q = `IA_SpellMenu` (action trigger **Released**, `bConsumeInput` false), P = `IA_SpellBook`, R = `IA_QuickAccessRadialToggle` |
| `IMC_SpellsUI` | **1–8 = `IA_Spellcasting_QuickAccess0..7`** (trigger Pressed), Q, P, H = emotes |
| `IMC_RadialSelection` | LMB = `IA_SpellsMenu_AcceptSelection` (Pressed), **F/G = `IA_SpellsMenu_SwitchRadialLeft/Right`** (previous/next wheel page), Gamepad_Right2D = `IA_SpellsMenu_SelectSlot` (Axis2D) |
| `IMC_SpellcastingMode` | **LMB = `IA_Spellcasting_PlaceSpell` (Released)**, Esc = `IA_Spellcasting_Cancel` (Pressed), mouse wheel = `IA_Spellcasting_AdjustSpell` (Axis1D), Q |

- Input modes (`pc.CurrentInputMode`): `DIM_Gameplay` at rest; `DIM_RadialMenu`, `DIM_SpellcastingMode`, `DIM_SpellPlacementMode` and `DIM_SpellPlacementModeAdvancedMovement` are in the PC properties of the same names.
- The live panel is `WBP_Spellcasting_MainPanel_C` under `/Engine/Transient...BP_DominionGameInstance_C` (the copy under `WidgetTree` is the archetype). It exposes:
  - its own input actions (`TriggerSpellRadialInputAction` = IA_SpellMenu, `ChangeSpellRadialRightInputAction`, ...);
  - `SpellRadialWidget` (`WBP_SurvivalSorcery_RadialSelector_C`), whose `QuickAccessInputActions` = QuickAccess0..7 and whose 12 `Slices` each have `SpellSlotNum` 0–11 (**within the page**) and `SliceIcon.Brush.ResourceObject`, the texture of the spell shown.
  - So **which page is open = compare slice icons with `SpellIcon`**. That is how `cast` checks that the open page shows the wanted spell before pressing its key, so it never casts another spell.
- Slots 9–12 of each page have no key (QuickAccess covers 8). Those spells answer `not_on_wheel` "sits in a spell wheel slot I can't reach yet". After the swap that includes **Windstep (index 35 = page 3, slot 12)** and the Enchant Weapon spells.
  - Phase C idea: the gamepad path, i.e. inject an `IA_SpellsMenu_SelectSlot` direction, read the radial's `SpellName` text, and Accept only when it names the wanted spell.

**After the 21:19 swap (`spells {all}` live):**
- 38 unlocked; Fishnado is locked.
- Reachable by key, among others:
  - page 1: Axtral Projection 1, Splinter 2, Trunk Totem 3, Bark to Bones 4, Superheat 5, Overdrive 6, Magical Mending 7, **Tempest Shield 8**;
  - page 2: **Summon Shelter 1**, Personal Chest 2, Internal Alchemy 3, Bones to Peaches 4, Uproot 5, Humidify 6, Rapid Growth 7, Mucksplosion 8;
  - page 3: Rocksplosion 1, ... Fire Spirit 8;
  - page 4: Phase Dash 1, Recall 2.

**Search (search-before-building):** no Dragonwilds or UE4SS spellcasting automation found. Game controls: allthings.how "how the spellbook menu and wheel work" (Q wheel, P spellbook, 4 loadouts of 12) and dragonwilds.runescape.wiki/w/Spells (costs, skill levels). Decision: adapt our verified Enhanced Input injection (combat/inventory) and build the state machine.
- **After the character swap (21:19 UTC; Attack 99, Agility 99, total level 1076), read live:** `PerkV2_Attack_Parry` unlocked = **true**, `PerkV2_Attack_MeleeSpecialAttacks` unlocked = **true**. `BP_GetPowerLevel` is still **2**: power level follows the gear, not the skills. Max HP 100, max stamina 60. Hands were empty (inventory being refilled).
- **North Star change (cold review):** a commanded `attack` is never refused for strength any more. Its reply carries `data.assessment {verdict likely_win|likely_lose|too_strong|boss|outnumbered, u_fight, est_s_to_kill, est_s_to_die, pl_gap}` as information. Mid-fight, a commanded fight flees only below the model's `combat_orders.flee_hp`. The reflex keeps its own vetoes, with its policy set by the model. Never-attack-players is the only hard gate.

**Live findings, Shockbyte world at night (about 20:35–20:45 UTC):**
- **The wheel input path works live.**
  - One injected frame of Q (`IA_SpellMenu`, Released) opens the wheel (`DIM_RadialMenu`).
  - G (`IA_SpellsMenu_SwitchRadialRight`) turns the page. The slice icons refresh about 0.4 s later, **not immediately**. Reading them at 0.3 s caused a run of page turns that never matched (the first scripted cast: `page_not_found`, safely refused). `cast` now waits until the icons actually change, up to 1.5 s.
  - **A page turn also changes the game's selected spell** (`GetCurrentlySelectedSpellData`) to that page's slot 1. No cast happens.
  - Q again closes the wheel.
  - `IA_RadialSelection_SwitchRadial` flips the panel's `WidgetSwitcher` to index 1, the **emote** radial. Don't use it. Q does not close the wheel while the emote radial is showing.
- **Placed spells:** the number key enters `DIM_SpellPlacementMode` (brain run, Summon Shelter page 2 key 1). Cleanup Esc (`IA_Spellcasting_Cancel`) left it cleanly, and no runes were spent.
  - The game's own preview is `AUtilitySpellPlacementVisualizer.bCurrentPlacementValid` plus the `CurrentAdditionalValidationInfo` tag (green/red). `cast` aims the camera at each candidate spot and releases LMB only on green.
  - **Lesson:** don't pre-filter spots strictly with traces. Ground near the start area has a 0.6–0.75 m spread over 3 m, so a 0.6 m limit dropped all 24 candidates (`no_spot` twice in the brain run). Traces now only rank and drop hopeless spots; the game decides.
- **Brain side:** `brain/spells.py MAX_ROWS = 12` cut Summon Shelter from `castable_spells` (14 castable after the swap). The model then said "isn't in my castable spells". The body now sorts castable rows first, and MAX_ROWS is now 40.
- **Sleep prerequisites (read-only `rest_probe.lua`):**
  - `IsNighttime` true, in-game 00:14, `PlayerRestComponent.IsInTimeframeForSleep()` true.
  - `pc.RestingInputMode` = `DIM_Resting`. `IMC_Resting` maps only E / Gamepad_FaceButton_Left to `IA_Interact` (Pressed), i.e. **E again leaves the bed**.
  - Rest texts: "Resting. Waiting for {PlayersNotInBed}/{TotalPlayers} players to sleep." and "Taking a nap to recover Rest, since it's too early to sleep through the night.".
- **Side bug (skills.lua fetch, reported):** in a pile of rune stacks, `fetch {item: "Earth Rune"}` failed with "keeps picking Air Rune", and `fetch {item: "Air Rune"}` with "keeps picking Water Rune". The detector targets the nearest stack. Fetching in the detector's order worked.
- **SUMMON SHELTER CAST BY CLAUDE (live, 20:44 UTC, brain-chosen `cast {spell: "Summon Shelter"}` with no target; Luis saw it):**
  - Path: Q → page turn → key 1 → `DIM_SpellPlacementMode`. The preview was green at a spot 1.5 m from the chosen one (spread 0.0). Then LMB (Released).
  - **The game then plays the cast animation in `DIM_SpellcastingMode`, and runes (Earth −10, Astral −10) are spent only after more than 4 s.** `cast` now waits up to 12 s while a spell input mode is open.
  - The result was `BP_Magic_SummonShelter_C_2147450308`.
  - The earlier attempts' preview tags: `UI.Notification.SpellPlacement.GroundNotFlatEnough` (trace spread ≥ 0.52 m over 3 m was rejected) and `UI.Notification.SpellPlacement.Blocked`.
- **`LastCastTimeBySpellData` uses the client's own world clock.** It read 1503.27 for Summon Shelter about 25 min after the client joined (`UGameplayStatics::GetTimeSeconds`). `GetServerWorldTimeSeconds` read 58000+ at the same time.
- **`PlayerUtilityMagicComponent.OurSpellActors` reads empty on the client** even with Claude's shelter standing (not replicated). `cast` matches the new `UtilitySpell` actor nearest its preview point instead.
- **Summoned shelter (client reads):**
  - One `InteractionComponent` ("Interaction", a SceneComponent) sits at the actor origin at ground level inside the tent.
  - Prompt: "Sleep" at night, "Rest" in daytime. Bed `LeaveActionText` is "Leave Bed"; `bRequiresClaimingToSleepIn` false.
  - Actor forward (-1, 0, 0) is the entrance side.
  - Approaching the actor origin walked Claude onto the roof (z +4 m), and the detector targeted nothing. Approach the entrance (origin + forward × about 1.5 m) and face the component instead.

## Capability contract + interact engine on the client (R2) (2026-10-25, 19:35-21:10 UTC, client build 26162923, Shockbyte world)
- **The interact "timeout" at 19:25 was a tooling foot-gun**, not a body bug. The `interact` cmd was in `client_io/bridge/brain_to_body.jsonl`: the SERVER body's file name. `tools/bridge_cmd.py` defaulted to `--body server` while DW_BRIDGE_DIR pointed at the client dir, so nobody read it. bridge_cmd now defaults to client and refuses a directory where that body never answered.
- **Summoned shelter geometry (live read, `client_mod/commands/skills_detector.lua`, read-only), BP_Magic_SummonShelter_C_2147461184:**
  - actor origin (398.89, 1746.96, -42.29); `GetActorForwardVector` (-0.996, 0.088);
  - `Interaction` (the InteractionComponent) sits AT the origin;
  - `InteractionCollider` sits at the ENTRANCE, (397.32, 1747.08, -41.0), 1.6 m out along forward;
  - `Bed` is valid (a component with no location).
  - Walking to the actor origin puts him on the roof (the 20:46 photo).
- **Sleeping in a shelter works through the real path (verified 20:57:40-47):**
  - the interact engine stood 1.5 m out from the collider along forward, faced the collider, the game's detector targeted the shelter with prompt "Sleep", and one IA_Interact press was made;
  - result `changed: "sleeping"`: PlayerRestComponent `CurrentRestingAreaActor` = the shelter, `CurrentRestingAreaComponent` = Bed, CharacterMovement `MovementMode` 0 (None), `IsSleeping` false afterwards;
  - Luis: "now its day" (the night passed).
- **Getting up = one plain IA_Interact press while resting** (verified 20:59:5x). The detector targets nothing while he lies there. After the press, MovementMode is 1 and the resting area is cleared; a straight go_to then walked him out of the entrance.
  - Movement input alone does nothing while resting: move.lua reported "walls everywhere" / self-stuck.
  - Movement tools now answer `resting` at once.
- **In-game clock reads on the client:** `UInGameTimeFunctionLibrary.IsNighttime(pawn)` / `GetInGameTime(pawn).Ticks / 3.6e10` returned hour 15.7 at 20:48 and 5.7 at 20:59, across a slept night. `PlayerRestComponent:IsInTimeframeForSleep()` read false (day). The hour formula is UNVERIFIED against the in-game clock UI.
- **Crash 21:49:34 (UTC+1 dump name; 20:49:34 UTC):** UE4SS `push_arrayproperty` right after move.lua's pause-menu Unstuck (teleport) fired twice while he stood on the tent roof.
  - The interact engine now always passes `allow_unstuck = false`.
  - sense/inventory/bridge array reads check the owner's IsValid in the same tick, and do nothing under DW_PAUSE.
- **Vitals damage hooks registered at the main menu never delivered a damage row:** rows exist only from the 17:53 in-world start, none after the 19:29/19:33/19:38 boot-time starts, despite a 36 HP hit at 19:43:53. The supervisor now re-registers them once `hooked_pawn` differs from the current pawn. This is a hypothesis fix, UNVERIFIED until a damage row appears after a boot.
- **Who dropped a world item:** `AWorldItem.NameOfPlayerCharacterThatDroppedItem` (FString), also `GuidOfPlayerCharacterThatDroppedItem` (reflection dump 26161880). It is read into census rows as `dropped_by`, UNVERIFIED live.
- **Collect-all exists in game data:** `UItemDeveloperSettings.CollectAllRadius` / `bCollectAllCollectsOnlySameType`, and `PlayerInteractionManager.SecondaryInteractAction` + `UInteractionComponent.SecondaryInteractionPrompt`. `interact {secondary=true}` presses the secondary action, UNVERIFIED live.
- **Real-model eval of the manifest tool list** (`evals/manifest_eval.py`, claude-haiku-5-5, 11 cases, **11 model calls**, 21:46 local; logs/evals/manifest_eval_20261025-214600.json): 9 PASS, 1 PARTIAL, 1 FAIL.
  - Pass: grave → interact(grave id); drink (hotbar) → consume; drink (on the ground) → interact + consume; "grab those" and "food and water in front of me" → interact on both dropped stacks; "give me the logs" → go_to(Zezima) + drop(Ash Logs); "come to me" → go_to; platebody → equip; bag food → move_item + consume.
  - Partial (fight prep at 29 % food): attacked without eating.
  - Fail (38 % HP after a fight): it asked "want me to eat some meat to heal?" instead of acting.
  - Both are judgement calls, left to the model and the vitals policy.
  - Speech was null on every action response: the model returned tool calls without text.
- **Spell special requirements (L1, live read 20:05 UTC+1):**
  - `UDominionSpellData.SpecialRequirementsStrategy` (TSubclassOf) → its default object (`cls:GetCDO()`) → `AreSpecialRequirementsMet(local PC)` (BlueprintNativeEvent, const) returns an FGameplayTag read as a Lua table with `TagName`, "None" when met. It was safe on all 14 classes Claude has.
  - Live tags: `UI.ConsumeItem.RequiresHeldMeleeWeapon` (enchants), `Item.Requirement.50uWater` (Humidify), `Item.Requirement.Compost` (Mucksplosion), `UI.ConsumeItem.RequiresHeldRangedWeapon` (Spectral Arrows), `UI.ConsumeItem.RequiresClaimedBed` (Home Teleport), `Item.Requirement.HeldFishingRod` (Infernal Rod).
  - The texts come from `SpecialRequirementsText`.
- **Keyless wheel slots (9–12):**
  - Injecting `IA_SpellsMenu_SelectSlot` (the Axis2D stick) does nothing to the radial: CachedSectionId stayed 0 in 12 directions.
  - The radial's own BlueprintCallable `HighlightSlice(9)` does set CachedSectionId 9 and SpellName "Enchant Weapon: Air", and it holds over later frames. The radial's `OffsetDegree` is 15 and `RadialMenuStickinessType` is 1.
  - So `cast` highlights the slot, checks that the name equals the requested spell, then presses `IA_SpellsMenu_AcceptSelection`.
- **Placement preview, live tags:** `UI.Notification.SpellPlacement.NoTarget.RequiresLog` (Splinter aimed off the log), `…GroundNotFlatEnough`, `…Blocked`.
  - **A splittable log's actor origin is stale.** Aim at `ATreeLog::GetMidPointWorldLocation` (here 7 m from the origin), and the preview turns valid at once.
  - **Splinter on a log, verified live:** `BP_Magic_Splinter_C` spawns at the preview, Earth −10 and Nature −5 are spent, and the log splits into "Ash Logs" world items.
  - After a placed cast the game may stay in `DIM_SpellcastingMode` for a moment. Don't press Esc then.
- **The bridge clock `api.now()` is `os.time`, in 1 s steps.** Sub-second waits in `spells.lua` use `UGameplayStatics::GetTimeSeconds`.
- **Spell demo, live (21:27–21:35 UTC, debug channel, arbiter idle before each cast):**
  - **Windstep** (index 35 = page 3, slot 12, keyless):
    - Presses: menu, next_page ×2, highlight + **accept**, place.
    - Air −5, cooldown started, `DominionStatusEffect` and tag `Player.Spell.WindStep` on the pawn.
    - **Jump apex 1.80 m → 7.38 m** (`smoke_jump.lua` before and after).
    - So the HighlightSlice + name check + Accept path is verified live.
  - **Tempest Shield** (page 1, key 8; the wheel opened on page 3 and wrapped round): Air −15, cooldown started, `BP_TempestShieldGameplayEffectInstance_C` replicated instance and tag `Player.Status.TempestShield`.
  - **Phase Dash** (page 4, key 1; the wheel remembers its last page): Astral −10, Air −20, cooldown started, no GE or tag (a Blueprint module plus ExpireAfterDuration).
    - Effect measured with `client_mod/commands/air_dash_test.lua` (jump, then one `IA_Player_Evade` press while falling).
    - Without the spell: 3.2 m peak horizontal, then the server **snapped him back to the start** (0 m net).
    - Right after casting: **8.4 m dash, kept**.
  - **Runes survive death.** Claude starved at 21:25:56. The hotbar and bag went to the gravestone, but the rune page stayed (Air 6589 …).

### Ranged aim: crossbows, bows and projectile spells (from the dump, build 26161880; NOT yet read live). Design: docs/design/ranged-aim.md
- **Flight parameters:** `URangedAmmoData.ProjectileData` (`FProjectileData`: `LaunchSpeed`, `OverrideGravityZ`, **`TimeWithoutGravity`** (a straight segment first), `MaxSimulationTime`, `LookAhead`). The equipped ammo comes from `PlayerRangedAttackComponent:GetEquippedRangedAmmoDataForCurrentWeapon()`. Charge: `PlayerRangedAttackCollection.LaunchSpeedCurve` / `OverrideGravityZCurve` (UCurveFloat by charge), `MaxChargeUpDuration`, `TimeBeforeFullAccuracy`.
- **Accuracy:** `BaseInaccuracy`, `GetCurrentArrowInaccuracy()`, `HasReachedFullAccuracy`, `IsAimModeActive()`, `HasRequiredAmmoEquipped()`. The aim is a camera trace (`AimOffsetTraceChannel`, `MaxProjectileTraceDistance`). The shot leaves the weapon actor's `ProjectileSocketName` (`AHeldRangedEquipmentActor`, `OwnedProjectiles`, `LoadedProjectile`).
- **Fired projectile:** `ADominionProjectile` (replicated `LaunchInfo {StartPosition, StartDirection, LaunchSpeed, OverrideGravityZ, LaunchTime}`, `ParentEquipmentActor`, `Multicast_OnProjectileHit`). Spell projectiles: `ADominionSpellProjectile.ProjectileMovement` (`InitialSpeed`, `ProjectileGravityScale`).
- **Catalog:** Adamant Crossbow primary "Shoot", special "Heavy Bolt" (32 damage, 50 charge), reload 2.0 s, ammo `CrossbowBolts`, projectile class `BP_Arrow_Base_C`. Crossbow `max_charge_up` 0.75 s; bow 1.55 s.
- **Engine helpers reflected:** `UGameplayStatics:BlueprintSuggestProjectileVelocity`, `SuggestProjectileVelocity_CustomArc`, `SuggestProjectileVelocity_MovingTarget`, `Blueprint_PredictProjectilePath_ByTraceChannel`. Not used: no straight segment, no learned parameters.
- **Built offline** (`client_mod/scripts/ranged.lua`, combat ranged engage; 29 + 8 checks):
  - The solver is a 1-D root search on flight time with lead and the straight segment.
  - The camera is aimed so its ray passes through `muzzle + dir·50 m`.
  - Firing: hold aim, wait for full accuracy, fire, reload.
  - Each real bolt is fitted (speed, gravity, straight time); learning keeps a capped pitch/yaw bias; hit/miss comes from our damage multicast.
  - Metrics by distance and target speed.
  - Fake-game result: 2 misses, then 5 hits, against a goblin strafing at 3 m/s at 20 m, starting from wrong seeds.

### Defensive abilities and telegraphs (2026-10-25, game data + offline; live proof owed). Design: docs/design/defense-abilities.md
- **Spell data (`data/spells_26161880.json`):**
  - **Phase Dash** `USD_PhaseDash`: Instant, 20 Air + 10 Astral, 45 s cooldown. Modules: PlayMontage, CostItems, Cast, Blueprint, `ExpireAfterDuration` 2 s, so it opens a 2 s window in which the evade is the dash. Owning perk `PerkV2_Agility_Spell_PhaseDash` (wiki: Agility 44).
  - **Windstep** `USD_Windstep`: Instant, 5 Air, 3 s cooldown, applies `GE_Windstep`. Its Wind Stomp landing (with `PerkV2_Agility_Spell_Windstep_Upgrade`) is a 700 cm, force-1000 stagger.
  - **Tempest Shield** `USD_TempestShield`: Instant, 15 Air, 45 s cooldown, `GE_TempestShield` (upgraded with `PerkV2_Attack_TempestShield`).
- **Readable at the AI attack telegraph** (`AiAttackComponent.CurrentAttack.AttackData`): damage times, montage and `GetPlayLength`, `MaximumRootMotionScaling`, `bLeaveNavMesh`, `NextAttack` (combo), flags (Special 4, ComboFinisher 8, ForceBlast 16). combat.lua now records all of these. The lunge distance and the attack's damage are learned per attack key.
- **The spells module's cast refuses while fighting** ("I can't cast while I'm fighting yet"), and its wheel route takes about 0.5-1.5 s. Combat needs `spells.ability_status` / `spells.cast_now` (contract in the design doc). Until then the abilities are reported unavailable.
- **Pre-casting (offline, 2026-10-25):** the spells contract is live (`ability_status` / `cast_now`, latency 0.7–2.05 s; Phase Dash 2.05 s). Combat now has a per-frame cast manager, learns each creature's attack rhythm, pre-casts Phase Dash so its 2 s window covers the next expected impact (one dash per cast, so used up by the dash) and Tempest Shield against dangerous attackers. Pre-cast and reactive answers are learned as separate bandit arms. Offline: a lunge every 3 s with a 1.6 s wind-up is dashed through after 3 hits (8 seeds stable). Live: still owed.

## Benchmark observer probe on the dev world (2026-10-25 ~22:47 UTC, client build 26162923, dev server 127.0.0.1:7777, character ClaudeDev; Eval agent)
- **What:** `client_mod/commands/bench_probe.lua` (read-only; uses only `mod/body/util.lua`) run through the DWClient command runner (`tools.scenario_run.run_client_cmd`). The client had joined the LOCAL dev server: game log `UPendingNetGame::SendInitialJoin ... RemoteAddr: 127.0.0.1:7777` and `LoadMap: 127.0.0.1/Game/Maps/World/L_World?...` (22:32 UTC). No live brain was running.
- **Result (0.5 s round trip, twice):** `ok`; the reads that work on the client pawn:
  - `GameplayStatics:GetTimeSeconds(pawn)` client world clock (864.98 s, then 877.44 s);
  - position `K2_GetActorLocation` (62.6, 1881.5, -35.4 m: the church start area);
  - health `HealthComponent:GetAuthoritativeHealth()` = 100, max `HealthComponent:GetMaxHealth()` = 100 (the property `HealthComponent.MaxHealth` reads **0.0**: don't use it);
  - vitals `SustenanceComponent:GetCurrentSustenance()` 30.8, `HydrationComponent:GetCurrentHydration()` 24.8;
  - inventory `pc.InventoryComponent.ItemSlots` -> {ITEM_Torch: 1} (a fresh character);
  - skills `pc.SkillComponent.Skills[].SkillData` + `GetSkillLevel` + `CurrentXP`: all 12 skills of the game data present by display name (Agility, Artisan, Attack, Construction, Cooking, Farming, Fishing, Magic, Mining, Ranged, Runecrafting, Woodcutting), level 1, xp 0;
  - GE instances, gameplay tags, `LastCastTimeBySpellData` and UtilitySpell actors: empty (nothing cast yet). An empty Lua table JSON-encodes as `[]`: the Python side normalises `cooldowns` to a dict.
- **Not read by probe v1 (they evaluate null, never pass):** held-item effects, ground items, creatures, other players' inventories. Those come from the dev referee (server side) once it is verified.
- **Build note:** the client and dev server report build **26162923**, while the data catalogs (`data/*_26161880.json`) were generated at 26161880. RUNBOOK-patch says to regenerate the catalogs after a patch. The benchmark's `game_build` is read from the catalogs, so a regeneration re-opens validity (by design).

## Benchmark referee + fixtures on the dev server (2026-10-25 22:50-23:00 UTC, server build 26161880 / Net CL 254097, DW_SERVER_ROLE=dev, ClaudeDev; Eval agent)
- **Entry:** `debug_run {"module":"bench","args":{"part":"referee"|"fixtures",...}}` (`mod/scripts/bench.lua` loads `mod/bench/*.lua` from the deployed mod root). Both parts refuse unless `DW_SERVER_ROLE=dev`.
- **Referee probe (read-only):** players from `FindAllOf("BP_PlayerCharacter_C")` with `PlayerState:GetPlayerName()` = "ClaudeDev", health 100, server `pc.InventoryComponent.ItemSlots` readable. Character GUID read as `U.guid_hex(ps.OwnerGuid.CharacterGuid.InnerGuid)` = `E71C5DC146F0A55B69FF52A881255DEF`. **Creature base class `BP_DominionAICharacter_C`** (`FindAllOf` returns subclasses): 8 `BP_AI_Kebbit_Character_02_C` (30 HP) and 4 `BP_AI_Magpie_Character_C` near the start area.
- **Referee polling (250 ms, LoopInGameThreadWithDelay, verified):**
  - `item_change` from the server inventory: torch drop -1 (client `drop`), pick-up +1 (client `interact` "Collect"), Coarse Animal Fur +1 (kebbit loot).
  - `damage` from creature health deltas: 8, 8, 8, 6 = 30 HP.
  - `death` with `kind_id = BP_AI_Kebbit_Character_02_C`.
  - Not covered by polling: damage type and attacker (polling can't see either), parry/dodge, projectiles, teleport (untested).
- **Fixture spawn (verified):** `World:SpawnActor(<class of a live BP_AI_Kebbit_Character_02_C instance via GetClass()>, pawn location + 4 m)` spawned a working kebbit on the server. It replicated to the client (`look` saw it at 4.03 m, 30 HP, alive), and Claude killed it with the real client attack path. No crash.
- **UDominionCheatManager (the game's dom* cheats) is reflected but INERT in this shipping build:**
  - The class is loaded (`/Script/Dominion.Default__DominionCheatManager`).
  - The PC has no `CheatManager`, and `pc:EnableCheats()` is a no-op.
  - `StaticConstructObject(DominionCheatManager, pc)` assigned to `pc.CheatManager` works.
  - But `domAddItem("ITEM_Resources_Stone", 3, 100)` added nothing, and `domModifySustenance(20)` left sustenance at 9.0. The cheat bodies are compiled out, so fixtures can't use them.
- **ClaudeDev survival:** server reads hydration **0.0**, sustenance 9.0 at 22:59 UTC (fresh character, no drinks).

## Client crash 2026-10-25 22:31:35 UTC after a disconnect (BUGS L24) + the game log that stopped at 22:04 (client build 26162923; read-only cdb)
- **Dump** `ue4ss\crash_2026_10_25_23_31_35.6102217.dmp`, `.ecxr; kn`: access violation `mov rax,[rcx]` with rcx = 0x250 (a null object + 0x250) in game code. Below it, two nested `UE4SS!...+0xcc7` frames separated by game frames, then the game-thread tick and the ProcessEvent path (`UE4SS+0x675`). No Lua frames.
  - "StartCallbackGarbageCollector" is only the nearest exported symbol. The installed UE4SS v3.0.1 release has no PDB, and the zDEV v3.0.1 build is a different binary (hash differs), so its PDB doesn't apply.
  - The +0xcc7 frames are UE4SS's native-hook trampolines: one for each RegisterHook'd UFunction in the call chain, calling the original.
- **What preceded it (logs/client/client.log, UE4SS.log):**
  - join_server 22:31:22, then disconnect 22:31:34;
  - two pause→re-arm cycles (22:25:03, 22:29:33). The vitals re-arm called UnregisterHook and then RegisterHook again on Multicast_ApplyDamage* / OnRep_*. In the UE4SS log only ONE of the four unregisters actually logged.
  - combat.lua hooked the same Multicast_* functions a second time.
  - UE4SS issue #484 reports UnregisterHook crashing games, depending on the hooked function, in v3.0.1 builds.
- **Decision (hookhub.lua):** one native post-hook per UFunction per process, never unregistered. Handlers are swapped in Lua; callbacks return before touching anything while DW_PAUSE is set; registration waits until a pawn is out of the front end. The ChatWidget UI hooks are dropped: they only counted, and widgets are the first thing torn down.
  - This fix is a reasoned inference, UNVERIFIED until repeated join/disconnect cycles on the dev world stay up.
- **The vitals re-arm (2026-10-25 evening) did deliver damage rows:** vitals.jsonl has 486 damage rows through 22:16. So hooks registered once in the world work. The hub keeps that property without re-registering.
- **The game log (RSDragonwilds.log) stopped at 22:04:11 UTC** in a session that ran until the 22:31 crash. Its backup file (`RSDragonwilds-backup-2026.10.25-22.04.11.log`, 2.9 MB) holds **27,162 lines of `LogPhysics: Warning: COLLISION PROFILE [Custom] is not found`** from 21:33 on.
  - Source: `move.lua` `raw_trace` traces with `LineTraceSingleByProfile(capsule:GetCollisionProfileName())`. On Claude's capsule the name is "Custom" (per-component collision, not a named profile), so EVERY trace warns and returns no hit.
  - Why the file stopped is UNPROVEN: the engine kept running (client.log continues), and the trace spam is the obvious anomaly.
  - Suggested fix for move.lua's owner: treat "Custom" (or any name the profile table lacks) as invalid, and trace by the capsule's object channel (ECC_Pawn) or fall back to the Visibility trace.
- **Server-side grant WORKS (verified 2026-10-25 23:0x UTC):**
  - The call is `pc.InventoryComponent:AddItemByData(ItemData, Count, 100.0, tags)`, where `ItemData = StaticFindObject(<catalog asset path>)` and `tags` is a COPY of a live, empty `FGameplayTagContainer` (`UItem.GameplayTags` of an item already in that inventory: the torch's `HeldEquipmentItem`). No struct is built in Lua (CLAUDE.md principle 4).
  - Stone 0 → 1, Air Rune 0 → 20; both replicated to the client (`bench_probe` inventory). No crash.
  - The game's `domAddItem` cheat is inert, so this is the fixture route (`mod/bench/fixtures.lua` verbs `grant` / `grant_runes`).
  - Limitation: it needs at least one item with empty tags already in the inventory.
- **Server-side spell unlock WORKS:** `pc.ProgressComponent:UnlockSpells({<UtilitySpellData object>})`, with a Lua array of a `StaticFindObject`'d `USD_Windstep`. The client's `spells` tool went from 0 unlocked to 1 (Windstep, castable). Fixture verb `unlock`.
- **Dev positive control (T0 Windstep) PASSED, judged by the harness probe:**
  - Claude's real `cast` (wheel: menu, quick0, place) spent Air 20 → 15 and set `LastCastTimeBySpellData` `USD_Windstep = 699.29`.
  - The tag `Player.Spell.WindStep` appeared on the pawn; GEs `DominionStatusEffect` and `HydrationDamageGameplayEffect` (the second is thirst, not the spell).
  - The cast reply agrees with the probe (no `sensor_mismatch`), so `spell_effect` passes on the specific tag. The base GE class is rejected as generic evidence.
- **A/B result (2026-10-25 23:16–23:30 UTC, dev world; driver `ab_cycles.ps1`: disconnect.lua → 12 s → client_boot -Target dev → 25 s):** every arm crashed on the **3rd** disconnect, right after `LoadMap(/Game/Maps/L_FrontEnd)` completed, with the identical AV (null + 0x250 in game code).
  - **hooks ON:** main's run at 23:04.
  - **hooks OFF:** the hookhub flag `client_io/state/hooks_off.flag` was set, and hookhub_status showed 0 native hooks. Crash dump crash_2026_10_26_00_19_49.
  - **UE4SS engine hooks OFF:** HookProcessInternal, HookProcessLocalScriptFunction, HookInitGameState, HookLoadMap, HookCallFunctionByNameWithArguments, HookBeginPlay, HookEndPlay, HookLocalPlayerExec, HookAActorTick, HookGameViewportClientTick and HookProcessConsoleExec were set to 0. Crash dump crash_2026_10_26_00_29_48.
    - In this arm the two `UE4SS+0xcc7` frames vanished from the stack. They were UE4SS's ProcessInternal/ProcessLocalScriptFunction detours: blueprint execution passing through, not a cause.
    - The ini was restored from `UE4SS-settings.ini.bak-20261026-L24` afterwards.
  - So it is a **game-side crash on the 3rd front-end return within one client process**: blueprint UI code dereferences a null object.
  - Each front-end load also logs `UMainMenuUIAPI::MainMenuWidget Called but a MainMenuWidget is already registered!`, so a menu widget is apparently re-registered every visit.
  - The 19:08 and 21:49 crashes are different: both are Lua-side (a UFunction call and a TArray read during teardown).
- **Probe v2 (client, read-only, verified live 2026-10-26 ~00:2x UTC on ClaudeDev):**
  - gear from `pawn.PlayerEquipmentComponent`: `CurrentBody/Legs/Head/CapeWearable` give `ITEM_Armour_T1_Body_Adventurers` and `ITEM_Armour_T1_Legs_Adventurers`; held items from `GetHeldEquipmentDataRight/Left()`;
  - held effects from `HeldEquipmentActorRight.Magical/PhysicalHeldEquipmentEffectInfo.EffectData` (empty: nothing held);
  - quests from `pc.QuestProgressComponent.Quests[]` (`Data` asset, display name, `State` EQuestState 0 Ungiven / 1 Given / 2 Complete, `CurrentObjective`). Example: First Steps (`Quest_FTUE_GS`) state 1 at Objective1; Dragon Slayer, Withering Heights and Black Knight Fortress state 0;
  - creatures from `FindAllOf("BP_DominionAICharacter_C")` within 40 m (3 seen);
  - world items from `FindAllOf("BP_RuntimeSpawnedWorldItem_C")` (`ItemData`, `GetStackSize()`);
  - other players: none.
- **Fixture `set_health` (verified):** `HealthComponent:SetHealth(80, "bench_fixture")` read back 80 server-side. It replicated (the client probe saw 66 seconds later, after starvation damage).
- **Fixture `teleport` (verified):** `pawn:K2_TeleportTo({X,Y,Z},{Pitch,Yaw,Roll})` returned true and moved ClaudeDev 5 m server-side; the client probe read the new position.
  - The earlier attempts returned false while he was at 1 HP and starving, so a near-dead pawn refuses to teleport.
- **Referee hooks (dev server, verified 2026-10-25 23:39–23:42 UTC with a spawned kebbit and Claude's real attack):**
  - **Doesn't work: `DamageComponent:BP_OnDamageReceived` never fires.** It isn't called through ProcessEvent. `FDominionPointDamageEvent` also has no Target field.
  - **Works: `PlayerMeleeAttackComponent:Multicast_SendDamageCacheData(TArray<FTimedDamageInfo>)`.** The component owner is the attacking player. Each `DamageInfo.DamagedActors[].PointDamageEvent` gives `Amount` (15.0), `TypeDamagesArray[].Types` (`DamageType.Physical.Slash`), `TypeDamagesOutcome` ([0] = neutral), `AttackId`, `bIsFatalHit` and `VictimLocation`; the victim is the actor nearest that point. The result is `damage {by: self, damage_type, ...}`, and a fatal hit gives `death {by: self}`.
  - **Works: `AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackClassId=365, AttackId)`.** This is the telegraph: the kebbit's attacks on Claude, AttackIds 1..10.
  - **Works: `AiAttackComponent:Multicast_SendDamageCacheData(FAiAttackOutcome)`.** It gives damage BY the creature (`by: BP_AI_Kebbit_Character_02_C`, 7.0 Slash to self).
  - **Registered, not yet seen firing:** `PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParried/BlockedAttack` (parry/block). For dodge, the pawn's `InvulnerableEvadeTag` is checked at the AI outcome (not yet seen).
  - **Hook callbacks dispatch** through `_G.__dw_bench_ref_dispatch`, so a redeployed referee.lua takes effect without re-hooking. RegisterHook can't be undone, and the v1 callbacks are silenced by a state flag.

## Foliage ids go stale when he walks up to a tree (BUGS L26; client build 26162923; offline fix 2026-10-26)
- **Observed** (dev run T0, debug channel lines 250-263): `go_to fol:BP_InteractableFoliageISMC_Tree_C_12:59` arrived 1.4 m from the Ash Tree, and then the same id resolved to nothing.
- **Cause:** the server's `NearbyFoliageConverterComponent` (Range 300 cm) converts the instance into its `ActorClass` actor (e.g. `BP_BM_Tree_Ash_03_C_2147454756`) and hides the instance (instance scale 0). gather.lua logs the same "adopted <actor> (was fol:...)" on every approach (client.log 2026-10-25 20:01, 20:03, 21:05, 21:16).
- **Also:** an instance index is not an identity (ISM/HISM RemoveInstance swap-removes), and a foliage component's name repeats per World Partition cell.
- **Decision:** a foliage id is `fol:<ActorClass>@<x>,<y>,<z>` (decimetres). `sense.resolve_foliage` maps it to:
  - the same instance;
  - the nearest same-class instance within 1 m (reindexed);
  - the converted actor of that class within 2 m (converted);
  - or reports felled_or_picked / not_found.
- All id-taking tools resolve through it (`client_bridge.lua` find_thing). See `docs/design/stable-target-ids.md`.
- **Cast settle, verified live (dev world, 2026-10-26 07:1x UTC):** Summon Shelter at (89, 1882):
  - Timeline: preview valid → LMB → the `BP_Magic_SummonShelter_C` actor 0.4 s later → the rune spend and the `LastCastTimeBySpellData` change about 6 s later.
  - So the actor replicates first and the spend and cooldown last. A cast reply must wait for both (L25).
  - Near the dev spawn lodestone (at 13–25 m from it) every shelter preview said `UI.Notification.SpellPlacement.Blocked`, even on flat ground; 40 m away it was accepted. Probably a no-build radius around lodestones (not confirmed in the data).
- **Referee v1.2 hooks REGISTERED on dev (2026-10-26 ~07:10 UTC; not yet seen firing).** Client→server RPC post-hooks for Luis's redefined long tasks: `InventoryController:Server_MoveItemBetweenInventories` / `Server_SplitAndPutStack` / `Server_MoveAllItemsBetweenInventories` (container deposits; "his" container = absent at referee start), `InventoryController:Server_CraftRecipe` (craft), `BuildModeComponent:Server_SpawnBuilding` (built), `FarmCommandComponent:Server_TryPlantSeed` / `Server_TryHarvestPlot` (planted / harvested). Live verification waits for a container, a station and plots on dev. Building needs the body build tool (capability agent).

## Build probes P1a/P1b (2026-10-26, dev world, client build 26162923; read-only, `client_mod/commands/build_probe_p1a.lua` / `build_probe_p1b.lua`)
- **Owners exist on the PC:** `BuildModeComponent` (bUseNewComponent=true, CurrentBuildMode 0=None, Prev 1, SnappingMode 0=Basic), `BuildPlacementComponent`, `BuildInteractionComponent`, `BuildValidationComponent`. The input mode was `DIM_Gameplay`; the spells agent reports Oculus is another build-like mode, `DIM_OculusBuildMenu`.
- **Actions** (read from the component, not asset paths):
  - `CancelAction` = IA_Building_Cancel, `ModifyRotationAction` = IA_Building_RotateZ, `GhostModifierAction` = IA_Building_GhostPiece_Modifier;
  - `BuildingMappingContext` = IMC_BuildingGeneral;
  - BuildInteractionComponent `InteractAction` = IA_Interact, `QuickInteractAction` = IA_Building_QuickInteract.
- **Limits:**
  - placement: `MaxPlacementDistance` = `SelectionMaxPlacementDistance` = 700 cm, `MaxDistanceModifier` 350, `MaxHeightModifier` 300;
  - interaction: `MinTimeBetweenBuildingPlacementRequests` = 0.25 s, `DetectionRange` 1500;
  - settings CDO: `ModifyRotationStepDeg` = 15, height step 0.05, distance step 0.4, `MaxNumPieces` 8192;
  - `PieceTagToMaxCountMap` = {BaseBuilding.PieceType.Prop.ProtectionTotem: 8}; `TagsToCountsMap` on the client = {} (empty: the counter does not replicate, or there is nothing here).
- **Catalogue:** `BuildPieceCatalogue` is loaded (`DA_BuildPieceCatalogue_Default`).
- **MPC:** `MPC_BuildingPieceGhost`, with params `PlacingValidityStateIndex` and `CursorWorldPosition`.
- **`ValiditySpawnStateToScalarIndex` is NOT one-to-one:**

  | Scalar | States |
  |---|---|
  | 2 | Valid (0), NeedsSnapping (4) |
  | 1 | Overlapping, Floating, NeedsFoundation, Unstable, MissingMaterials, InsideVault, InsideProtectedArea, ReachedCountLimit, InsideBlockedRegion |
  | 0 | WrongPhysicalSurface (7), None (13) |

  ShelterCheckFailed (11) is absent. **So the MPC scalar cannot tell Valid from NeedsSnapping, or WrongPhysicalSurface from None.** It is a colour index, not the state. The exact state needs the `OnValidityStateChange` / `OnValiditySpawnStateChanged` post-hook, or another property (P4).
- **The game's own words** (`BuildInteractionComponent.ValidityNotificationTextMap`):

  | State | Text |
  |---|---|
  | 1 Overlapping | "Blocked" |
  | 2 Floating | "You can't place this in the air." |
  | 3 NeedsFoundation | "You need a foundation to build this." |
  | 5 Unstable | "Unstable" |
  | 6 MissingMaterials | "You require more materials to build this." |
  | 7 WrongPhysicalSurface | "You can't build here" |
  | 8 InsideVault | "You can't build here" |
  | 9 InsideProtectedArea | "Only the Host can build here." |
  | 10 ReachedCountLimit | "Placement limit reached for this piece." |
  | 11 ShelterCheckFailed | "You can only place this outside" |
  | 12 InsideBlockedRegion | "Cannot be placed in this region" |

  There is no text for 0 or 4.
- **Privileges** (`PlayerState.PrivilegeComponent:HasPrivilege`): Build=true, OpenChests=true, Chat=true, Owner=false.
- **Unlocks:** `ProgressComponent.BuildingsUnlocked` holds 42 entries **with duplicates** (the 16 Deluxe Edition decorations appear twice), 26 unique. Useful ones:
  - `BUILDPIECE_CraftingStation_Basic` "Crafting Table" (4 Ash Logs, 20 xp, idx 433);
  - `BUILDPIECE_Campfire` "Campfire" (6 Stone, 20 xp, idx 26, `ShelterRequirementText` "Must Be Exposed");
  - `BUILDPIECE_Interior_BedRoll` "Bedroll" (20 xp);
  - `DA_BaseBuilding_Building_Protection_Totem` (**bOnlyAvailableToHost = true**, 0 xp);
  - decorations (1 xp).

  `bFarmingUnlocked` = false. `Category` reads "None" on Campfire and Crafting Table. Requirements read cleanly as `TArray<FResourceRequirement>` via `ForEach` + `:get()`. **No chest, no farm plot, no rune altar is unlocked on dev.** Unlocks come from item/actor discoveries (DISCOVERIES crafting).
- **`HUDUISubsystem.BuildingAPI` exists headless:** 1 `BuildingUIAPI` object. `GlobalBuildingManager`: 1, with a `CounterComponent`.

### Dev-world combat diagnosis (2026-10-26, from logs; docs/design/combat-basics-live.md)
- **Server evidence (dev server log, category `EvadeAttack` Verbose):** `TryPerformAttack ... starting attack on authority against player`, `PredictPointDamage ... will receive D damage` / **`evaded 0.000000 damage`** (a successful dodge), `DomNetActIntIds: AUTH : Action Accepted : START : Evade|Block`, `DominionBlockComponent AuthorityApplyBlocking : BlockDelay [0.117] for REMOTE player`.
- **Client:**
  - The AI attack multicast arrives about 40 ms after the server starts the attack.
  - `Multicast_SendDamageCacheData` ("received damage event on client") arrives at the impact: Kebbit +1.30 s; its data says 1.35 s.
  - No `DamageComponent` damage multicast reached the client for the Kebbit's hits; only HP polls showed −7.
  - Client log: `Player_AckRequestStartBlocking: BlockTime = Now + ~0.10`.
- **Results:**
  - 22:56, 3/3 dodges evaded (server-verified).
  - 23:39, 8/8 hits landed through "blocks": a stale `DIM_OculusBuildMenu` input mode delayed the input, and the blocks arrived inside the server BlockDelay.
- **ClaudeDev:** total level 12 (Attack 1), so `PerkV2_Attack_Parry` (Attack 5) and the specials (Attack 8) are locked.
- **The Stone Logging Axe's block action (`PA_Block_PickAxe`) cannot parry.**

### Dev-world combat live M1 (2026-10-26 07:55-08:21 UTC, client build 26162923, server build 26161880, ClaudeDev vs spawned Kebbits; combat agent; docs/design/combat-basics-live.md §4)
- **Equip check:** shield goes to the left hand; dagger to the right, actor `BP_Dagger_Bone_C`; the Stone Logging Axe (two-handed) shows in **HeldLeft**, actor `BP_Logging_Axe_Stone_C`. `unequip {slot = HeldRight}` was verified. `unequip {item}` through the bridge hit the bridge's own `R.unequip` route, not skills' verified `HANDLERS.unequip`.
- **Dodges (server `PredictPointDamage ... evaded`):** run 1 evaded 2/4 (both directions measured: left gives right_cm about -250, right about +200), run 5 evaded 23/24, run 7 evaded 10/14. Runs 2-4 had too few attacks, or he retreated when stamina ran low (max stamina 40). Fixed by `defence_reserve`, which keeps stamina for the next dodge, plus the learned swing cost.
- **Disengage + eat (orders `{defense="auto", disengage=true, heal_hp=0.5, reengage_hp=0.8}`, HP set to 40%), 3 passes:**
  - 08:0x: healed 33 -> 63 -> 93 and re-engaged.
  - 08:17: a telegraph arrived mid-disengage, so he defended, went back to the disengage, ate, and the heal 33 -> 63 was verified during the loot phase.
  - 08:20: healed 40 -> 63, then won.
  - **Bug found and fixed:** live at 08:11, a defence started from the disengage cleared `F.dis`, so the bite was never verified. Now the disengage survives a defence, and a pending bite is verified on every tick in any phase (test 11b).
  - On a Kebbit, the disengage usually ends with `enemy_closed_in`, because a chasing Kebbit keeps up.
- **First server-confirmed block:** `will receive 0.000000 damage` at 08:20 (the Tempest Shield follow-up). Tempest Shield was cast live through `spells.cast_now` (abilities `{tempest_shield: 1}`) in runs 1 and 3.
- **Reach underestimate:** a "none (out_of_reach)" plan was hit twice while retreating, because the Kebbit chases. `defense.feedback` now records `hit_from_cm`, and `threat.reach_cm` is at least that distance.
- **Parry perk:** `PerkV2_Attack_Parry` read as unlocked at 08:16 (total level 32).
- **Parry, k=3 passed (09:33-09:44 UTC, Bronze Shield in the left hand, right hand empty, orders `{defense="parry"}`, 4 Kebbits):** 4 of 4 Kebbit attacks were parried. Each has three pieces of evidence:
  - the client's `PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack` verdict (combat logs `defence parry -> parried`);
  - the server's `PredictPointDamage ... will receive 0.000000 damage`;
  - the server's block timing. The block was active (`START : Block` plus `BlockDelay` 0.116) **0.060 / 0.034 / 0.071 / 0.097 s before the impact**. The impact is the server `AUTH ATTACK : TELEGRAPH` line plus its `TimeUntilEvent`.
  - For comparison, the plain block at 08:20 went active 0.365 s early and was not a parry. So the parry window is at least about 0.10 s, and the press-time formula `T - 2L - block_delay - window/2` lands inside it.
  - The server logs no parry line of its own (no "parr" text anywhere). The scratchpad driver's `parry_evidence()` computes the lead from the lines above.
  - With the Bone Dagger in the right hand, a 30 HP Kebbit dies in 2 hits before it can attack, so the trials fought bare-handed with the shield.
  - `BP_AI_RuntGoblin_Character_C` is still `unknown_class` to the spawn fixture (not loaded on the dev world).
  - A Kebbit spawned 5 m in +X was behind a wall, so the approach was stuck until the fight timeout (the local plan reported `unreachable_in_window`). Spawning at -4 m worked.
- **Hit while looting (09:41):** a second Kebbit hit him 4 times (7 damage each) during the loot and restore phases, and nothing answered it. No damage multicast reaches the client for AI hits, so nothing recorded the Kebbit as an attacker. Fixed:
  - an HP drop within 0.8 s after a creature's `Multicast_SendDamageCacheData` impact event now records that creature as the attacker;
  - loot and restore check every 0.5 s for an `attacked_me` threat and fight back;
  - a commanded fight now also retargets a creature that is hitting him. Self-defence only; a target that is merely near is still not engaged.
  - Covered by offline test 11a. The live repeat could not reproduce it (the second Kebbit stayed passive).
- **False "hangs" (ops, not combat):** the client watchdog (pid 4228, started 2026-10-25 23:09 UTC) kept the **old** `Invoke-ClientCmd` in memory. That version writes `wd_boot_probe.lua` but never appends it to `client_io/cmd/queue.txt`; the queue runner went live at 07:41 UTC. So every watchdog probe timed out, and about 4 minutes after each boot it declared a hang and killed a healthy client: 08:04-08:08, 08:13:10 and 08:17:54, with `mod_log_age_s` 0-2 s. Evidence: no `ran wd_boot_probe` in client.log between boots, while `m1_*` commands ran. Fix: restart the watchdog (`tools/start_client_watchdog.ps1`) so it loads the current `client_lib.ps1`.

## Skills probe P1: fishing, agility, runecrafting actors (2026-10-26 ~08:45 UTC, dev world, client build 26162923, ClaudeDev; read-only `client_mod/commands/skills_probe_p1.lua`; design `docs/design/every-skill-coverage.md`)
**Fishing nodes.**
- 11 `FishingNodeV2` actors were in client relevance. Classes are `BP_FishingNodeV2_Net_Brynmoor_C` / `BP_FishingNodeV2_Rod_Brynmoor_C`; the nearest was 27 m from the spawn area.
- `DisplayNameText` reads "Net Fishing Spot" / "Rod Fishing Spot". `PowerLevel` is 2.
- `CompatibleToolCategory.TagName` is `Item.Equipment.Tool.Fishing.Net` / `...Fishing.Rod`. This is **identical to the item `Category` tag** of the nets and rods (items catalog `category_tag`), so tool ↔ spot matching by tag is verified.
- `IsDepleted()`, `IsBlocked()` and `IsInUse()` are callable from the client: all false here. They agree with `NodeState.bDepleted`.

**Pawn `FishingComponent`** (`BP_PlayerFishingComponentV2_C`).
- `Settings.TimeToFullyChargeRod` = 3.0 s and `RodCastLaunchAngle` = 30.
- `RodChargeFractionToProjectileSpeed` = `Curve_Float_RodChargeFractionToCastSpeed`. `GetFloatValue` is callable: 0 → 800, 0.5 → 1460.5, 1 → 1800.
- `RodFishingInputActions` are `IA_FishingMiniGame_MoveLeft`, `IA_FishingMiniGame_MoveRight`, `IA_Fishing_Reeling` and `IA_FishingMiniGame_Exit`.
- Idle `InternalState`: CurrentActivity 0, CastResult 4 (None), FishingResult 3 (None), SessionId 0, TimeOfLastActivityChange 0. These are all readable.
- `PlayerInputBufferInputActions.PrimaryAction` = `IA_PrimaryAction`.

**Agility.**
- `Default__AgilitySettings.WalkingXPEventTriggerDistance` = 602 (cm), event "Walking". Passive Agility XP is roughly one event per 6 m walked.
- No `AgilityCourseStarter`, `AgilityCourseManager` or `AgilityOrb` was within relevance of the spawn. Chasm Dash is NW of Bramblemead Valley (wiki).

**Runecrafting.**
- 3 `BP_AnimaVent_C` at 64–106 m. `HasAvailableCharges()` is true on all three; one has `IsConcentrated()` true.
- 5 `RuneEssenceGeyser` at 17–106 m (`BP_RuneEssenceGeyser_{B,C,J}_C`).
- No farm slots and no kebbit burrows in range.

## Benchmark: raise_skills route, server-log dodges, judge-side spell signals (2026-10-26 07:35-07:55 UTC, server build 26161880, DW_SERVER_ROLE=dev, ClaudeDev; Eval agent)

**Raising skills (fixture `raise_skills`, verified, QUICK variants only).**
- Route: on the server, `pawn.Controller.SkillComponent:AddXpFromEvent(SkillData.DamageXPEvent, "bench_fixture", Multiplier, true)`. The `FDataTableRowHandle` is read from the live `USkillData.DamageXPEvent` property; it is never built by hand.
- **The XP lands on a later tick.** A read of `SkillComponent.Skills[i].CurrentXP` in the same call shows no change. This is probably because of `SkillComponent.XPBatches`.
- Attack amounts: ×1 gave +1 XP and ×10 gave +8 XP (bIgnoreModifier = true), so about 0.8 XP per multiplier unit.
- `GetTotalXPNeededForLevel(L)` works. The fixture is therefore one step per call: add `(needed − current) × 1.15` units. The harness repeats it (up to 6 rounds, 1.5 s apart) until the level is ≥ the target.
- Verified: Attack 2 → 3 at 71 XP. Level 2 is reached at XP 33.
- **Side effect:** ClaudeDev's Attack went from level 1 at 32 XP to level 3 at 71 XP during verification.
- The XP leaves gain `CurrentXP` and level through `GetSkillLevel(SkillData)`. Wrapper objects of one SkillData do not compare equal with `==`, so match on the short name.

**Dodges are server-authoritative in the dev server log.**
- The source is `RSDragonwilds.log`, category EvadeAttack, Verbose. Timestamps are UTC.
- `TryPerformAttack() : [..] <AI> starting attack on authority against player <pawn> with id N` marks a telegraph.
- `PredictPointDamage() : [..] <pawn> evaded 0.000000 damage at T from <AI>` marks a successful dodge.
- `... <pawn> will receive D damage ...` marks a hit.
- `<pawn>` is the object name, for example `BP_PlayerCharacter_C_2147373968`. The referee's `start` reply now returns it.
- `evals/bench/serverlog.py` tails the log. On dev it is the source for `telegraph` and `defended how=dodge`; the client-hook versions of those are dropped.
- **Blocks:** the server logs only `DomNetActIntIds: AUTH : Action Accepted : START/STOP : Block` and `AuthorityApplyBlocking() : BlockDelay`. Neither names the player, and no outcome line was seen. The blocks in the logs so far were made without a shield, and every one of those hits did full damage. The wording for a blocked or parried hit is still to be captured on the first shield fight.

**Judge-side spell signals.** The probe reads them (`bench_probe.lua`) and never trusts the cast reply.
- `pc:GetViewTarget()` returns a class word, and `pc.CurrentInputMode` a DIM_* asset. The spells agent verified both live.
- Eye of Oculus leaves its view inside the cast, after about 3–5 s (L29). The referee therefore also polls `BP_OculusCamera_C`; it has not yet been confirmed that this actor exists on the server.
- Transient signals (view target, input mode) evaluate to null when absent, never to fail.
- Enchant Weapon (Fire) is checked by `held_item_effect` on the probe's `held.effects`, which reads `HeldEquipmentActorRight.MagicalHeldEquipmentEffectInfo.EffectData`, for example `HEED_EnchantWeaponFire`.
- **Referee v1.4 (registered on dev at 07:58 UTC; not yet seen firing):** RegisterHook succeeded for `/Script/Dominion.OculusPawn:Multicast_OnOculusActivated`, `/Script/Dominion.PersonalInventoryComponent:OpenPersonalInventory` (EPersonalInventoryOpenMethod Manual=0, Spell=1) and `:Client_TogglePersonalInventory`. It also polls `pawn.OculusComponent:IsOculusActive()` every 250 ms. All of these emit `spell_state`.

## Director live smoke, run 1 (2026-10-26 07:46-07:52 UTC, dev world, client build 26162923, server build 26161880; Director agent; docs/design/director.md §14)
- **Setup:** `DW_DIRECTOR=1 DW_DIRECTOR_CALLS_PER_HOUR=10 tools\start_brain.ps1 -Body client -World dev_director`. `session_start` showed world=dev_director and director=true. The job came in by CLI: `tools/board.py add "chop 5 ash logs, then drop them on the ground next to you" --world dev_director`. Log: `logs/brain-live-20261026-084634-10200.jsonl`.
- **What worked:**
  - Inbox ingest happened on the next tick.
  - Real Sonnet researched (recall, map_memory, look) and planned explore → chop → drop with checkable core predicates.
  - Board runs verified each step from state, e.g. "Ash Logs +6/5" and "Ash Logs -5/5 left the inventory".
  - A failed step (no progress twice) became a DEPS replan ("trees here depleted, explore further"), which then worked.
  - The hourly window held: 7 Sonnet requests, then the job went to `waiting_budget` and a notice was voiced.
  - There were no director_error or board_quarantined rows.
  - Step-to-step gaps were p50 3.0 s, almost all Haiku thinking (`tools.obs task`).
- **Job did not finish (Director bug, fixed offline):** Sonnet's done test was `all[gained Ash Logs 5, lost Ash Logs 5]` since the job began. Both read the same net delta, so it can never pass. The tally reached 13 logs collected, with three drops of 5. The Validator now sends this back for repair with the reason, and suggests tally + on_ground (`director.net_conflicts`, test `test_gained_and_lost_of_one_item_in_one_test_go_back_for_repair`).
- **Controller ran ahead:** in the first step ("explore to find ash trees") Haiku did the whole job (gather + drop), so the later steps counted nothing. STEP_INSTRUCTIONS now say "do this step only: the job's later steps come to you as their own steps". This is information, not a veto.
- **Voice bugs (controller/voice owners):**
  - Haiku's content "EMPTY" was **said in chat** 3 times; the rest were suppressed only as near-duplicates.
  - "hey! what we up to?" was said at the start of a body-initiated board run, twice.
- **Survival:** hydration fell to 18.7/75 with no drink; the reflex Clean Water use failed (`reflex_use_failed`).
- **Spend:** Sonnet 7 requests ($0.11). Haiku made **38** Controller calls ($0.024), **over the 20 I had stated**. That is 12 board runs at 2–4 turns each plus notices. A future smoke needs a hard Controller-call stop, not only an estimate.

## Build probes P2–P5 (2026-10-26 ~08:2x–08:3x UTC, dev world, client build 26162923)
- **P2, the place key:** `IMC_BuildingMode` maps **`IA_Building_QuickInteract` = LeftMouseButton** (the place / quick-interact click). `IA_PrimaryAction` is NOT mapped in build mode: a press of it placed nothing (P5 attempt 2).
  - Also in `IMC_BuildingMode`: RotateZ / OffsetZ / OffsetDistance = MouseWheelAxis, Cancel = Escape, BuildMenu = B, FreePlacement = Y, GhostPiece_Modifier = F, DestroyObject = MMB.
  - `IMC_BuildingUI`: SelectPiece = LMB, GenericBack = B, tabs Q/E.
  - Build input modes: `DIM_BuildMenu` (Selection), `DIM_BuildMode` (Placement), and DIM_OculusBuildMenu / DIM_OculusBuildMode / DIM_OculusRepairMode.
- **P3, B toggles the menu:** IA_BuildMenu, one injected frame → `CurrentBuildMode` 1 (Selection), input mode DIM_BuildMenu. **One Cancel from Placement goes straight to None.**
- **P4a, selecting a piece:** `BuildingUIAPI:CallOnBuildingItemSelected(<UBuildingPieceData>)` while in Selection → Placement (2), DIM_BuildMode.
  - `CurrentlyPlacingPieceData` is a **TWeakObjectPtr**: read it with `:Get()`.
  - The preview is a real **actor** (`BP_Station_Campfire_C`, `bIsPreview` = true, `PlayerControllerManagingPlacement` = our PC). Its location equals the MPC `CursorWorldPosition` (the vector's R, G, B = X, Y, Z in cm).
  - `SetControlRotation` moves the preview: aiming works.
- **MPC `PlacingValidityStateIndex`:** 1 with 0 stone (MissingMaterials). After 6 stone were granted (dev fixture, harness setup) it read 2 at every ground spot ~4–6 m away.
- **The validity hooks NEVER fire.** These stayed silent across the 1→2 change, re-selects and aim changes, although both registered natively: `BuildModeComponent:OnValidityStateChange` and `BaseBuildingActor:OnValiditySpawnStateChanged`. They are called from C++, not ProcessEvent, and no validity property is reflected. → Press rule changed (main approved): MPC == 2 AND the preview within match_m of the spot AND a fresh read after the latest aim plus wait.
- **Snap pieces:** colour 2 also covers NeedsSnapping. The data signal is the preview actor's loaded `BuildingPieceDerivedData.PlacementProfileRowHandle`, read with UE4SS `DataTable:FindRow(RowName)`, then `.bCanOnlyBeSnapped`.
  - Campfire → `FloorPropNonOverlapProfile`: bCanOnlyBeSnapped = false, bCanOnlyBePlacedOnDefinedSurface = true.
  - Snap-only or unreadable → no press (`preview_ambiguous`), a known limit until a positive snap signal is found.
  - The preview's `BuildingSnapComponent.Plugs` is NOT a usable discriminator: the Campfire has plugs.
- **P5 PASSED:** `build {piece: "campfire"}` → presses menu, select, place (QuickInteract), cancel → ok.
  - spent `{ITEM_Resources_Stone: 6}`.
  - evidence = **telemetry**: `Client_TelemetryOnBuildingPieceComplete` is a Client RPC and its post-hook DOES fire.
  - Construction XP **+12** (not ConstructionXPOnBuild = 20: multipliers apply, as the review said).
  - Build mode was None afterwards.

## Live checks: fishing, talk P1, talk P2 attempt (2026-10-26 09:00-09:28 UTC, dev world, client build 26162923, ClaudeDev; skills-coverage slot)
Quick fixtures, logged as quick and not M3 cases: Coarse Net and Ash Rod were granted through `DevTarget.setup("grant")`.

**Net fishing works end to end.**
- `fish {count: 2, method: "net"}`: walked to the nearest net spot, equipped the Coarse Net, held the trawl once, and caught 2 Raw Shrimp. Fishing XP rose by 8 (the SkeletalComponent rows). Took 17.8 s.

**Rod fishing is partly working.** Casting, the landing correction, bites and reeling work; fights are lost to stamina.
- **Input modes.** With the rod in hand the PC sits in `DIM_SpellcastingMode` (the rod's cast is a magic-attack action). The bite/fight runs in `DIM_Fishing`.
  - Both are this action's own input modes.
  - Fix in fishing.lua: the tool's baseline mode, and any mode once fishing has begun, no longer gate our own hold. Build, container and conversation screens still block.
  - Before this fix, every cast restarted ("cast N" loops), and one run ended with a false `screen_open`.
- **Casting.**
  - Charge 0.45 landed at 19.4 m; the model predicted 12.6 m.
  - The learned correction settled at k ≈ 0.61–0.67 (`landed / predicted`), after which casts hit the node.
  - `CastResult` values seen: Missed_HitWater (2) and Hit_ValidNode.
- **Junk.** Junk (Weeds, Stone, Goblin Pack) arrives without a fight. A late junk item was once miscounted as a fish; now only `FishingResult == CaughtFish` counts as a fish.
- **Fight trace** (fishing_status.fights):
  - while the fish swims, his `PlayerStaminaFraction` falls about 12 %/s and the fish's only about 2 %/s;
  - while it rests, holding `IA_Fishing_Reeling` moves ReelProgressFraction from 0 to about 0.74 in about 5 s, and the fish's stamina falls about 12 %/s;
  - his stamina hits 0 at about 12 s, and the fish escapes.
- **Pull experiments.**
  - The same-side pull drained him about 30 %/s, so the opposite pull (wiki) is the right direction. A stamina-drain swap rule was tried and rejected.
  - Pulling nothing at all drained him at the same ~12 %/s. So either the drain comes from the fight itself (Ash Rod = lowest tier; wiki: better rods drain less), or the injected `IA_FishingMiniGame_MoveLeft/Right` presses do not reach the minigame. **[UNVERIFIED which]**
  - He now rests to 95 % stamina before each cast.
- **Fishing XP.** It rose on escapes and junk too (+12 over one run with 0 fish).

**Talk P1 (read-only, hooks registered).**
- `ConversationComponent` = `BP_Components_PlayerConversation_C`. Its `DomConversationParticipant` lives on the PAWN (`...BP_PlayerCharacter_C_*.DomConversationParticipant`). Idle: ConversationsActive 0.
- `WBP_Conversation_MainPanel_C` exists on the headless client: `ContinueInputAction = IA_UI_ContinueConversation`, `CancelInputAction = IA_UI_GenericBack`, 4 `OptionSelectInputActions`, `OptionSelectMappingContext = IMC_Conversation`.
- With no conversation open, the panel's participant is unset. talk.lua now accepts an unset participant.
- Both count-only hooks registered natively: `ConversationParticipantComponent:ClientUpdateConversation` and `PlayerConversationComponent:BP_HandleConversationUpdated`. The client stayed healthy.
- Quests read: First Steps state 1 (Objective2), and the others Ungiven.
- NPCs in relevance: `BP_NPC_WiseOldMan_FTUE_C_*`, `BP_NPC_Doric_FTUE_C_*`, Vannaka (`SkeletalMeshActor_*`), all with prompt "Talk".

**Talk P2 blocked by perception.**
- The census row for the Wise Old Man reports a position near the world origin (look distance 1865 m). His actor is at (61.3, 1873.6, -35.5) m, 8 m from Claude.
- The shared interact episode, used by both `interact` and `talk`, walks toward that point (water_ahead / no_route) and times out without pressing E.
- Reported to the capability agent (sense owner). No conversation opened; talk was disabled again after the attempt.

**Starvation.**
- ClaudeDev died of hunger and thirst at 09:24:08 UTC (sustenance and hydration 0) during this slot. He carried no edible food: the Raw Shrimp are not edible.
- He respawned at the FTUE start area with 25/75 food and drink.
- **Fixture `set_time` (verified on dev at 10:4x UTC):** on the server, `BP_InGameTimeActor_C` (`AInGameTimeActor`, implements `IInGameTimeProvider`) provides `GetInGameTime()` → FTimespan `{Ticks}` (1 tick = 100 ns) and `SetInGameTime({Ticks=n})`.
  - The value is TOTAL in-game time (day 53 at hour 1.1), not the hour of the day. Crop timers are stamped in it, so the fixture only moves the clock forward.
  - Measured 01:07 → 01:30: `SetInGameTime` took effect immediately, and the clock read 01:35 five seconds later.
  - The server log at 2026-10-25 22:47 showed `DominionInGameTimeSubsystem: Failed to find an actor that implements IWorldTimeProvider` (a different interface).
  - Not yet checked: whether the change replicates to the client (`bench_probe.game_hour`).
- **Slot results, 2026-10-26 09:45–09:55 UTC (dev, Eval agent):**
  - **Axtral Projection T0 passed** at the standing-trees spot `evals/bench/dev_places.json` `[100, 1892, -31]`: two Ash Trees about 8 m away, the lodestone 49 m away. Evidence: `spell_actor BP_Spell_AxtralProjection_C`, 3.9 s, 2 Haiku calls.
  - **Route A (fresh character per case) verified live.** `CD_m3w05d8_sure0` was created through `create_char.lua`: first boot stops at the menu, create, second boot picks it by name and joins dev with the client relaunched (L24). The server GUID `F201088A…` came from the referee probe.
  - **`raise_skills`, all-but-Woodcutting to 10, on that character:**
    - 8 skills reached 10.
    - Mining overshot to 19: its DamageXPEvent gives about 3 XP per multiplier unit, against Attack's about 0.8.
    - Fishing, Magic and Agility stayed at 0 XP, because their DamageXPEvent gives NO XP.
    - Fixed offline, not yet re-run live: an adaptive step (a quarter of the gap first, then the measured ratio, aiming at 97%), plus skill-specific live row handles: Magic `PlayerMagicComponent.SpellDamageXpEvent`, Agility `SprintComponent.SprintXpEvent`, Fishing `CatchableFishSpeciesData.Info.NormalDrop.OnFishingXpEvent`.
  - **Enchant Weapon (Fire) T0:** the hold setup (the body's `equip` on the granted sword) succeeded. The cast then answered "couldn't find Enchant Weapon: Fire on my spell wheel's pages" (verification_failed) after the unlock. That is a body/spell-wheel issue.
  - **Runt spawn (M1):** the spawn fixture now loads a not-yet-loaded class with UE4SS `LoadAsset(<full path>)` + `StaticFindObject`. The paths are in `evals/bench/spawn_classes.json` (runt: `/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/RuntGoblinVariant/BP_AI_RuntGoblin_Character.BP_AI_RuntGoblin_Character_C`). It is deployed but not verified: the fixture needs the character in the world, and the client is down (BUGS L35).

## Client lodestone fast travel (design + offline build, 2026-10-26; dump 26161880; NOT yet live)
- **Route (the player's path, never a position write):**
  1. Use the lodestone (`BP_WorldLodestone_C`, prompt "Teleport") through the shared interact episode. The map opens: `UMapUIAPI:IsShowingMap()`.
  2. `UBaseTeleportationComponent:TryTeleport(FromId, ToId)` on his PC's `LodestoneTeleportationComponent`. This is the local function the map's lodestone click calls; it sends `Server_TryTeleport`.
  3. Verified by the `Client_OnTeleportSuccessful(TargetLocation)` Client-RPC post-hook AND his position within 25 m of the destination's RespawnLocation.
- **The ids passed are the LIVE `FGuid` structs** read from `AGameplayObjectRegistry.Lodestones` (`FLodestoneData` {Location, RespawnLocation, Identifier}), never built in Lua.
- **Gates are read before any walk or press:** `CanTeleport` false → `not_unlocked`; `CanAffordTeleportationCost` false → `missing_materials` (Law runes, with `GetTeleportationCost`).
- **The retired server-puppet route is NOT used:** `mod/body/travel.lua` K2_TeleportTo.
- **Built:** `client_mod/scripts/lodestone.lua` (tools `lodestones` read, `teleport` action with `llm=false` until live) and `client_mod/tests/test_lodestone.lua` (13).
- **UNVERIFIED live:**
  - that the press opens the map headless;
  - that TryTeleport from Lua starts the teleport;
  - that the success RPC hook fires;
  - that IA_UI_GenericBack closes the map;
  - that two lodestones are both unlocked anywhere on dev (DISCOVERIES l.584: proving CanTeleport true needs a second built lodestone).

## Director live smoke, run 2 (2026-10-26 14:54-14:57 UTC, dev, ClaudeDev fresh, client build 26162923; Director agent)
- **Setup:**
  - bridge_start first; build is listed.
  - World dev_director_r2; job "make yourself a wooden shield" via the CLI.
  - Hard guard at 20 Haiku / 10 Sonnet. The guard stopped the brain at 20 Haiku calls; Sonnet made 7 requests.
  - Log: `logs/brain-live-20261026-155436-3456.jsonl`.
- **Not finished (no shield).** The task is still active at "Gather 14 Ash Logs".
- **What Sonnet got right from data:**
  - Wooden Shield = 10 Ash Logs at a Crafting Table, unlocked by holding ash logs with a table near;
  - the Crafting Table costs 4 Ash Logs (buildables);
  - the trader route (30 Garou Chit per log) was rejected;
  - his near-death state (0.5 HP, hydration 0) came first.
  - On the replan it found the real chicken-and-egg: no axe; Stone Logging Axe = 8 Ash Logs + 6 Stone at a Crafting Table, which itself needs ash logs.
- **Findings:**
  1. **The client crashed** at 14:56:19 (crash dump `crash_2026_10_26_15_56_19.0234266.dmp`, pid 7080) during `explore`. Free RAM was about 1.5 GB. The watchdog relaunched it (boot ok 14:57:10). The board run got `body_restarted` on explore and go_to, and said so truthfully.
  2. **Hallucinated fact:** the first plan listed "I have a Stone Logging Axe" as known. He carried no tools; the replan corrected it.
  3. **Steps tested only by elapsed time** ("Recover the gravestone", "Set vitals policy") passed although their tools failed. Fixed offline: the Validator now gives one advisory for a working step tested only by time (information; the model may keep it).
  4. **The first-axe bootstrap:** the answer is already in this file ("Ground gatherables", interact_probe 15:58 UTC). Ground "sticks" are `BP_Spawner_AshBranch_0x_C` with `ItemData = ITEM_Resources_Wood_Ash` ("Ash Logs"), prompt "Collect", and no tool is needed. But gather_profiles `sticks` still has item nil, so `gather ash` resolves to the trees (wrong_tool without an axe). For run 3, the body needs that profile item set, or the model must use interact/gather "sticks".
- **obs task:** wall 183 s, idle 7%, longest idle 3.8 s. Lead-in 26 s (25 s of Sonnet thinking). Gaps p50 0.13 s, p90 0.56 s, all dead time, under 1 s each.

## Live checks 2026-10-26 15:05–15:40 UTC (ClaudeDev, dev world, skills slot)

- **Survival root cause:** at 15:06 hydration reached 0 and HP fell because he **carried no drink or food at all**. The stay-fed reflex was running (no error, nothing marked bad) but emitted nothing, since it only warned about bag-only items. The 14:59:37 "blocked: build Placement" event fell inside a live build, released at 14:59:39, so it was not the cause.
  - Fix: `reflex no_drink`/`no_food` events. Seen live at 15:37:47: "no drink carried, hotbar or bag".
  - Fix: a safety-floor exit from build/container screens, `input.leave_modal_step`.
- **skill_routes, M3** (`logs/skills/routes_20261026-161533.json`): 0 passed, 4 failed, 8 skipped.
  - **Loose stones give no Mining XP.** `gather stone` resolved to the ground pickup, returning "Got 2 stone" with Mining 3 → 3. The profiles are now split: `stone_boulder` (Mining) vs `loose_stones` (`trains=false`), and a bare "stone" resolves to the category.
  - **Lock-on is a gameplay mode.** Combat's own lock-on puts the PC in `DIM_Gameplay_LockOnTargeting`; it was read as a blocking mode. `input.is_gameplay_mode` now accepts `DIM_Gameplay_*`.
  - **Campfire targeting.** The craft at the Campfire failed: the interact focus kept picking an adjacent `BP_BM_Sapling_Ash_01_C` (handed to the capability agent).
- **First-axe bootstrap, verified live:** `gather {resource:"ash", count:2}` with no axe collected 2 `ITEM_Resources_Wood_Ash` from `BP_Spawner_AshBranch_03_C` ("Collect", interact key, no tool, 5.7 s). The reply was "Got 2 ash from sticks (no usable logging axe for ash)". The fallback is profile data: the same item, a tool-free source, in range. Floor logs = these branch pickups; felled-tree logs still need an axe.
- **Rod fight trace (Ash Rod, Brynmoor rod spot; 3 fights, all lost):**
  - **Pulls do reach the minigame.** `FightingFishPlayerInputValues.PullingRodValue` reads ±1 matching the pressed direction.
  - **While the fish swims (L/R):** the reel stays at 0.00; HIS stamina falls about 8.5 %/s and the fish's about 2.5 %/s.
  - **While it rests (r) and he reels:** the reel rises about 14 %/s, the fish's stamina falls about 12 %/s, and his falls only about 2 %/s.
  - **Outcome:** the reel peaks at 0.72–0.76 when the second swim starts, and his stamina reaches 0 about 16 s in, so he loses.
  - **The earlier `pull_mode="none"` experiment was void:** the override was applied after the hold was set, so it still pulled. Fixed, and `pull_mode="reel"` was added. A real A/B is still pending: the one "none" try got junk, then the Goblin Runt killed him mid-fishing with the rod in hand (combat reflex: 4 presses, 0 hits).
- **talk P2 (Wise Old Man FTUE):**
  - **First try:** the dialogue DID open (`DIM_ConversationUI`, his first line in `LastMessage`), but `ConversationsActive` stayed 0 and `CurrentNPC` was unset on the client. talk therefore said "no conversation opened", leaving the panel up and the reflex blocked.
  - **Fix:** the conversation input mode also counts as active.
  - **Retry:** it opened, read 3 lines, and `hook_count` went 1 → 4 with content changes (counter proven). `leave` ended it (node inactive, no input owner left).
  - **Options:** the node offers "Yes please [Begin Tutorial]" / "I can work it out [Skip Tutorial]". Both change quest state, so no "harmless choose" exists here; that is left for P3 on a fresh devchar. The reply's `options` list was empty while the node signature listed both (to check).

## Director live smoke, run 3 (2026-10-26 16:05-16:10 UTC, dev, ClaudeDev; Director agent)
- **Setup:** bridge_start first; the sticks profile fix (18a2626) was in. World dev_director_r3; job "make yourself a wooden shield". The guard stopped the brain at 20 Haiku calls; Sonnet made 7 requests. Log: `logs/brain-live-20261026-170459-9940.jsonl`. memory_low 0; free RAM about 1.27 GB; no client crash.
- **Not finished.** The job is active; 0 Ash Logs.
- **The bootstrap route resolved correctly:** `gather {resource: ash, count: 14}` with no axe went to `resource: sticks`, item ITEM_Resources_Wood_Ash.
- **But he could not reach the branches:** `path_blocked` after 120.9 s. The phase log shows 3 approaches (21.8 m, 11.8 m, 16.3 m), each `scan unreachable timeout` after 40 s ("I can't get to the sticks (timeout), and the last 3 I tried were blocked too"). This is a locomotion gap at that spawn (for the move/locomotion owner).
- **Survival took over:**
  - Hydration was low. He found a pond (BP_WaterVolume) and tried `interact` on it 4 times, always `too_far`.
  - He said truthfully that he had no bottle or bucket and asked the player for a waterskin.
  - He fought a Kebbit, and that fight looked well (dodge, Tempest Shield, hits).
- **Replan:** "find a woodcutting tool" first. The Director did not learn that the sticks route exists, because gather's failure said "can't get to the sticks" and the plan read it as "no hatchet". Information for the model: the gather detail now names sticks.
- **obs task:** wall 317 s, idle 2%, longest idle 0.7 s. Lead-in 15.6 s (14.6 s of Sonnet thinking). Only one step ran, so there are no step gaps.

## Drinkable water for a fresh character (research 2026-10-26, game data build 26161880 + wiki + our live logs; Director run 3 question)
- **No container is needed, and there is no direct "Drink" from water.**
  - Water bodies are interactables `BP_WaterVolume_C` / `BP_WaterVolume_NoSlow_C`, and the census reads their prompt as **"Collect Water"** (live 2026-10-25, e.g. `BP_WaterVolume_NoSlow_C_UAID_00BE4395530E3F5202_1116071179`, 14 m from the start crate).
  - Game data lists "Get Water" as a world interaction (filling from a source), not a wheel spell.
  - The wiki: Dirty Water "can be collected from ponds or any accessible body of water" (dragonwilds.runescape.wiki/w/Dirty_Water, /w/Hydration).
  - No other water prompt has been seen. No waterskin, bottle or water bucket exists in the item or recipe data: the only "containers" are farming Watering Cans (`RECIPE_Tool_WateringCan_Wood`: 4 Ash Logs + 1 Coarse Thread) and Compost Buckets.
- **The water itself:**
  - `ITEM_Consumable_Water_Dirty` (DrinkItemData, stacks to 99): +10 hydration, +20 Soulscourge (damage over time at 100), so a few are fine and many are not.
  - Clean Water (+25 hydration, no Soulscourge) comes from `RECIPE_Consumable_Water_Clean_From_Water_Dirty`: 1 Dirty Water at a **Campfire or Grill** (processing station: load + fuel, 4 s, collect), Cooking XP.
  - The recipe is unlocked by owning Dirty Water (`ALL ITEMS[ Dirty Water ]`, DT_Progression_Food_Drink), so it appears after the first collect.
  - The Campfire is buildable from the start (build primitive verified live 2026-10-26), and crafting.lua's processing path already handles campfire recipes.
- **Bootstrap chain:** collect Dirty Water ("Collect Water", interact key, one per press), then drink one only if desperate (Soulscourge), then build or use a Campfire with fuel, boil, and drink Clean Water.
- **Body gap: water-source interact fails.**
  - Every live `interact` on a Water Volume (2026-10-25/26, about 10 tries) ended `too_far`, "I can't get close enough to the Water Volume", at **0.88–0.97 m** from the chosen spot after 6 spots.
  - Cause (skills.lua go_to/near check): the approach spots for the volume's surface point lie at or in the water. move.lua's water avoidance ("entered water, re-planning round it") stops him at the edge, and `near` requires `d <= spot tol + 0.3`.
  - **SPEC (skills.lua, capability owner):** a target whose census kind is a water volume (data: class/prompt from the census, no name list):
    - **(1) Approach:** the nearest DRY standing point within `reach_m` (2 m) of the surface point; arrival = 2D distance to the surface point <= reach_m (`tight` off).
    - **(2) Face** the surface point with the camera pitched down (W.face(ipoint)), so the interaction detector targets the volume (check `interact_target` reads the volume / "Collect Water" before pressing).
    - **(3) Press** interact once and verify a +1 `ITEM_Consumable_Water_Dirty` within verify_s.
    - **(4)** `count` > 1 repeats the press (the source never depletes, per the wiki), stopping at inventory_full.
    - **(5) Failure reasons stay truthful:** `not_interactable` ("the water doesn't take", with what the detector targets), and `too_far` only when no dry point within reach exists.
  - **Stay-fed reflex:** it should NOT drink Dirty Water above the safety floor (Soulscourge); below the floor, Dirty Water beats death. The brain gets `no_drink` and decides to collect and boil.

## Spell re-run findings + multi-step mechanics (2026-10-26, offline from logs/evals/20261026/20261026-163357-dev-measure)
- **The case errors were the model-call budget**, not the body: Fire Spirit and Vengeance cast ok and verified, then the model went on (consume, re-cast into the cooldown) until the cap hit. An ok cast carried no sentence, so the body now adds one ("I cast Vengeance: used 20 Astral Rune; it's recharging now.").
- **Fishnado / Fishing Frenzy:** cast on a fishing node id from `fishing_spots` returned "I can't see what you want me to aim at". The bridge census (sense) doesn't list `FishingNodeV2` actors, and go_to answered `target_not_visible` for the same id. spells.lua now resolves any actor id the census lacks through the live actor (class = id up to `_C`, one FindAllOf). The census gap itself belongs to sense/go_to (capability).
- **no_valid_aim "requires multiple logs" / "requires rune" / "requires fishing node"** are the game's own placement tags, and they are truthful. Trunk Totem and Runes to Rune Essence then succeeded after the model prepared the ground (dropped a rune, moved to logs).
- **Recall** (Luis + wiki "place a temporary beacon ... return to it within a limited time"; the game's only `AllowMovementThenCastInstant`): one cast leaves it PREPARED (`SpellBeingPreparedOrCast` = USD_Recall), no runes, no cooldown = the beacon is down. A second cast returns. The time limit is not found (wiki and metaforge are silent). The body treats it as two steps, from data/spell_mechanics.json `two_step`:
  - step 1 answers "beacon placed at [x,y,z]";
  - step 2 is verified by arriving within 4 m of the beacon.
- **Divine Rock / Enfeeble / Rapid Growth were declined by the model, correctly:** no ore on the ground, nothing hostile in sight, no crops. ClaudeDev was also at 1% HP with 0 hydration, so it put survival first. The tool list wasn't misleading; the cases lack their world preconditions.
- **Multi-step / conditional mechanics, from the wiki snapshot:** written to `data/spell_mechanics.json` (35 spells, non-judge, with sources) and exposed as `how` in state.spells:
  - drop-then-cast: Runes to Rune Essence (drop the runes), Divine Rock (drop 5 ore), Magical Mending (drop the damaged items), Bones to Peaches (bones on the ground);
  - cast-on-a-thing: fishing node (Frenzy, Fishnado plus a tool of the node's power), fallen trees (Trunk Totem, Splinter), standing tree (Bark to Bones), plots (Rapid Growth, Mucksplosion with 150 compost, Humidify with a 50-water can), fire stations (Superheat), mechanical stations (Overdrive);
  - equipped tool: Infernal Rod (rod), Spectral Arrows (two-handed bow, not a crossbow);
  - carried tool: Rocksplosion (pickaxe), Axtral Projection (axe);
  - timed charges: Surge (3 dodges, 2 min), Windstep (7 s), Phase Dash (3 air dashes);
  - Internal Alchemy only refreshes ACTIVE food/drink buffs.

## Recall, live 2026-10-26 17:35–17:39 UTC (ClaudeDev) + sources
- **Live behaviour:**
  - Selecting Recall opens `DIM_SpellPlacementModeAdvancedMovement`, a placement mode he can move in (move.lua isn't input-gated).
  - The place press spends 30 Air + 15 Law, starts the 75 s cooldown and plays a ~1 s DominionSpellActor. Pressed at once, he stays put (0 m).
  - A place press on an invalid spot does nothing; the mode stays open 12 s until cancelled. spells.lua now puts this mode through the validated spot search.
  - During the cooldown the game refuses it.
  - A cast after the cooldown, 11 m from the previous one, cast again with no teleport.
- **Sources:**
  - Wiki revision https://dragonwilds.runescape.wiki/?diff=58751: "Leaves a runic marker on the ground; recasting teleports you back to it. Taking a fatal fall while tethered teleports you back safely and consumes the tether."
  - The marker's lifetime is not stated anywhere found (wiki, metaforge 403).
- **Next live test** (prepared in the scratchpad, applied after the freeze): `cast {spell: "Recall", walk_to}` opens it, walks while it is held, then finishes it, judged by position. It tests whether the mark is where the cast is opened and finishing it brings him back.

## Recall hold-and-walk, live 2026-10-26 19:38–19:41 UTC (dev, Claude's client, build 26162923; probe `client_mod/commands/recall_probe.lua`, 0.5 s samples)
- **The mechanic, verified:** the mark is where he stands when Recall is **opened**; finishing the same cast teleports him back to it.
  - 0–2 s: the wheel (`DIM_RadialMenu`), page turn, quick key.
  - 3.2 s: `DIM_SpellPlacementModeAdvancedMovement`, `SpellBeingPreparedOrCast` = `USD_Recall`, runes untouched (Air 380, Law 1460). The preview sits at his feet: `[97.97, 1865.76, -29.46]` with him at `[97.94, 1865.61, -30.69]`.
  - 3.7–6.4 s: he walks (`move.go_to`) while the mode stays open: 10.8 m to `[100.67, 1876.04, -30.59]` (`walk_result` arrived).
  - 6.9 s: the place press. Air 380 → 350, Law 1460 → 1445, the 75 s cooldown starts, `DominionSpellActor_2147465313` appears for ~1 s, the mode is `DIM_SpellcastingMode`. He is at `[97.95, 1865.68, -30.59]`, 0.1 m from the opening point. That is the teleport back.
  - 8.0 s: `DIM_Gameplay`. He stays at the opening point for the rest of the 40 s.
  - Result: `cast {spell: "Recall", walk_to: [100.5, 1877.3, -31.6]}` → ok, `returned: true`, `from_opened_m` 0.1, `walked_m` 10.8, presses menu, next_page, quick0, hold_walk, place.
- **A later recast does not return:** after the cooldown he walked 11 m away to `[100.65, 1876.02]` and cast plain Recall (menu, quick0, place). It spent 30 Air + 15 Law, started the cooldown and moved him **0 m**. A finished Recall leaves no lasting marker, so the wiki's "recasting teleports you back" is the place press of the same cast. spells.lua's hold-and-walk model matches. Recall is not `two_step` in `data/spell_mechanics.json` (updated `how`/`observed`).
- Result fields (spells.lua, after 20:00 UTC): `landed_at` = where he ended up (the snapshot after the cast); `placed_at` = where the place press and its spell actor were (the walk's end). `from_opened_m` / `returned` judge the return. `cast` without `walk_to` on this cast type is refused up front (`walk_to_required`): opened and finished on the spot it moves him 0 m and still spends the runes. The two-cast beacon code is removed.

## Item-name resolution and station-output pickup (2026-10-26, Claude's client, dev)
- **consume name matching, live-verified 19:38 UTC:** only a Water Rune on the hotbar, no Clean Water. `consume {"item":"Clean Water"}` and `{"item":"water"}` → `not_in_inventory`: "I don't have any Clean Water on me, and I can't see one nearby. (Water Rune isn't something I can eat or drink.) I have nothing to eat or drink on me." (`carried_consumables` []).
  - Before the fix it answered `not_consumable` "I can't eat or drink the Water Rune". The cause: `skills.find_carried` took any partial `match_score` overlap (the word "water") as a match.
  - The shared rule is `client_bridge.M.resolve_name` (`api.resolve_name`). A match is an exact id or name, the whole words inside the name or id, or every word matching. A partial overlap is only `near`, never a match. consume lets only consumables match fuzzily. `inventory.find(list, what, prefer_kind)` prefers the requested consumable kind among substring hits.
- **Station output pickup** (live failure 19:3x: "the game targets BP_Station_Campfire_C…, not the Clean Water"):
  - The detector (`UInteractableDetectorComponent`) casts a camera ray (`CameraRayLength`) and a forward character trace (`CharacterTraceDistance`), so whatever lies *behind* a small item on his line of sight wins a near miss.
  - crafting's collect step hand-built its episode. It had no `ipoint`, so `W.face(nil)` never aimed, and no `small` flag, so other sides were never tried.
  - It now uses `skills._new_episode(..., {avoid = station position})`. Standing spots are 0.9 m from the item, in this order: beside it (±90°), between the item and the station, the far side last.
  - The other-sides retry for any small item now avoids whatever the detector picked instead. It also fixes a mirror bug that dropped the far side rather than his own.
  - `client_bridge.aim_at` now aims from `PlayerCameraManager:GetCameraLocation()` (like `spells.W.aim`), not from the pawn's centre.
  - Live re-check of the Campfire pickup: **not yet done** (needs Dirty Water and fuel).

## HUD screens and the input mode: InputManagerUIAPI (2026-10-26 19:02–19:18 UTC, dev, ClaudeDev; BUGS B-stuck-focused-ui)
Builds: client 26162923, dump 26161880.

### The API
- **`UInputManagerUIAPI`** (Dominion.hpp l.24430) owns HUD widgets by `EWidgetType` (Dominion_enums.hpp: Crafting 6, Inventory 11, Map 13, Processing 15, LorePopup 31, Runecrafting 36, …).
  - `IsOpen(PC, Type)` → bool.
  - `CloseWidgetIfOpen(PC, Type, bIsTriggeredByOutsideWidget, bShouldCheckPauseBlock)` and `OpenWidgetIfClosed(...)`. Plain enum/bool arguments, no structs.
  - `CurrentlyActiveWidgetForController` names the focused panel.
  - The PC's input mode (`CurrentInputMode`, DominionInputMode assets under `/Game/Gameplay/Inputs/Modes/`) follows the open widgets.

### Verified live
- **The stuck state:** after a Campfire craft, IsOpen gave {10 InteractionPrompt, 11 Inventory, 15 Processing}, active = `WBP_Inventory_MainPanel_C`, mode `DIM_FocussedInGameUI`.
  - `CraftingUIAPI:HideCraftingUI(15)` changed nothing.
  - IA_UI_GenericBack/Accept/UnFocusRequirements and `RefreshInputMode()` did nothing either (earlier agent).
- **The close:** `CloseWidgetIfOpen(PC, 15, false, false)` closed 15 AND 11 (coupled), and the mode read `DIM_Gameplay` in the same call.
- **Opening Inventory:** `OpenWidgetIfClosed(PC, 11, false, false)` gives `DIM_MainInventoryMenu`, and `CloseWidgetIfOpen(PC, 11, …)` returns to `DIM_Gameplay`.
- **Screen input modes** (object dump): DIM_FocussedInGameUI, DIM_UnfocussedInGameUI, DIM_FullScreenUI, DIM_FullScreenUIMap, DIM_MainInventoryMenu, DIM_CraftingMenu, DIM_AgilityCourseUI.
- **Used by:** `input.lua` (`close_screens`, `open_screens`, the `"screen"` modal, `after_action`), `crafting.W.close` and `lodestone.W.close_map`.
- **CommonUI idiom** (the Epic "Input fundamentals for CommonUI" doc): close or deactivate the widget through its owner and let the input config follow. Never call SetInputMode directly.

## Client crash L38: -nullrhi makes every Niagara spawn NULL; the player character stores and dereferences it (2026-10-26 19:30–20:35 UTC, client build 26162923, dev, ClaudeDev; cdb on the UE4SS dumps + static reading of the shipped exe + live reflection; read-only except the fix)
- **All 8 dumps of the family are one bug.** They are the 2026-10-26 18_08_10, 18_26_17, 19_04_07, 19_11_08, 19_20_03 and 19_24_52 dumps (local time, `Win64/ue4ss/crash_*.dmp`), plus the repros 20_24_07 and 20_25_57. Each shows the AV at `exe+0x64AEC4A`: `mov rax,[rcx]` with rcx=0, then `call [rax+2C0h]`.
  - The function (`exe+0x64AEAE0`) is **`ADominionPlayerCharacter::RemoveNiagaraSystemWithLocalTag(Tag)`**. It looks Tag up in `LocalFX` (`TMap<FGameplayTag, UNiagaraComponent*>` at pawn+0x1748; the CXX dump gives that offset), then calls the component's virtual (Deactivate), `DestroyComponent` (dl=1) and `Remove`. It has no null check.
  - Its caller (`exe+0x64AEE40`) is the tag-changed handler. It looks the changed tag up in `TaggedLocalNiagaraSystems` (`TMap<FGameplayTag, FDominionTaggedLocalNiagaraSystem>` at +0x1798, 0x38-byte elements) and calls Remove with the row's `LocalVFXTag`. It runs from a delegate thunk inside a multicast broadcast during the world tick.
  - In every dump, LocalFX holds exactly one element whose value is NULL. TaggedLocalNiagaraSystems holds one row whose key FName index (0x1f737) is the same across all runs.
- **The adder never checks.** `AddNiagaraSystemAttachedWithLocalTag(System, Tag, AttachPointName)` is at `exe+0x648D450`. It returns early when the tag is already held, or when the net mode is a dedicated server. Otherwise it calls `UNiagaraFunctionLibrary::SpawnSystemAttached(System, Mesh, AttachPoint, 0, 0, KeepRelativeOffset, bAutoDestroy=false, bAutoActivate=true, Pooling None, bPreCullCheck=true)` and does `LocalFX.Add(Tag, result)` **unconditionally**, even when the result is NULL.
- **The row (live read, `client_mod/commands/l38_fx_probe.lua`):** `Environment.SoulScourge` → `{LocalVFXTag = Player.Vfx.SoulScourge, System = /Game/Art/VFX/Library/Character/StatusEffect/NS_SoulScorge_PlayerEffect_Buildup, AttachPointName = spine_03}`. This is the Soulscourge build-up glow. Dirty Water (+20 Soulscourge) is the only consumable used so far that raises Soulscourge, and that is why only it crashed (0 of 31 other uses did).
- **Why the result is NULL (a headless client):** on Claude's -nullrhi client, `SpawnSystemAttached(NS_SoulScorge…Buildup, Mesh, "spine_03", …)` returns **NULL both with bPreCullCheck=true and with false** (`client_mod/commands/l38_spawn_test.lua`, live). So scalability pre-culling is not the cause. `fx.Niagara.Scalability.VisibilityCulling 0` did not help either (repro 2 still crashed).
  - In the shipped exe, `SpawnSystemAttachedWithParams` (`exe+0x50B96C0`) reaches `CreateNiagaraSystem` (`exe+0x50A09D0`). That function returns NULL before it creates anything, on `if (A && !B) return null; if (C) return null`, where A, B and C are three global bytes. That is the shape of `FApp::CanEverRender()`: `(!IsRunningCommandlet() || IsAllowCommandletRendering()) && !GUsingNullRHI`. The engine docs describe CanEverRender as the check for apps that never render or run headless with NullRHI.
  - Conclusion: with -nullrhi, **every** Niagara spawn returns NULL on this client.
  - Players (who render) and dedicated servers (Add returns early) never store a NULL, which is why this is a Claude-only crash.
- **Repro (dev, slot `l38`, 20:22–20:26 local):** fixture grant of Dirty Water, then `client_mod/commands/l38_drink.lua`, which runs inventory.lua's use path with crash_refusal bypassed in its own module instance only. A per-frame watcher (`client_mod/commands/l38_fx_watch.lua`) recorded:
  - the drink GE;
  - within 30 ms, `LocalFX = {Player.Vfx.SoulScourge = NULL}` with **no NiagaraComponent created** (NotifyOnNewObject saw none);
  - then the crash in the next frame.
  - Result: 2 of 2 crashed (dumps 20_24_07, 20_25_57). Why the Remove sometimes follows at once (the 16:55 and 16:58 drinks did not crash) is UNPROVEN, and the fix makes it irrelevant.
- **Fix (`client_mod/scripts/fxguard.lua`, client_bridge service `fxguard`, built like tickguard):** empty `TaggedLocalNiagaraSystems` on every live `DominionPlayerCharacter` on Claude's client: his own pawn and other players' pawns, whose tag events also run on his client. The tag handler then finds no row and never adds or removes a NULL. This covers every row, including any a patch adds. It is client-local and cosmetic, since a -nullrhi client never draws the effect. New pawns (respawn, join, other players) are caught by the 10 s service check.
  - Verified live: `fxguard_apply` emptied 1 row (`Environment.SoulScourge`) on `BP_PlayerCharacter_C_2147473178`. Then **3 Dirty Water drinks in a row on the same process (pid 1412) did not crash**, LocalFX stayed empty, and the Soulscourge status GE applied as normal. After a bridge restart, boot_probe shows `fxguard: running`.
  - Offline test: `client_mod/tests/test_fxguard.lua` (14/14).
- **Alternatives weighed:**
  - Rendering for real (dropping -nullrhi, e.g. -RenderOffScreen on WARP, since there is no GPU) would make CanEverRender true and fix every such site at once. It was not tried: it needs a software-rendered UE5.6 scene on a 4-vCPU VM with ~1.5 GB free.
  - Patching the NullRHI flag in memory would make the renderer call an RHI that does not exist, and needs approval anyway.
  - Culling cvars do not help: the NULL comes before culling.
- **The general rule this exposes:** on Claude's client, *any* game C++ that keeps a spawned VFX component without a null check is a latent crash. Native holders of UNiagaraComponent* from the CXX dump that are at risk:
  - `UTagActivatedFX.ActiveFXMap/ParticleSystems` (the same tag-driven pattern; the next guard candidate: its `FXSettingsMap`);
  - `AHeldEquipmentActor.FXSourceToAppliedFX` (enchant FX on held gear);
  - `UDominionStatusEffect.SpawnedVFX`;
  - `UDrainEffectManagerComponent.DrainVFX/BeamVFX` (spells);
  - `UDetectOreGameplayEffectInstance` ping VFX map and set (ore detection);
  - `UPlayerEnvironmentFXExtension.MoveThroughWater/PassThroughVFXComponent` (wading has been fine so far);
  - `ADominionProjectile` arrow head and trail;
  - `AFelledTree.CanopyCollapseVFXComponent` (woodcutting has been fine so far);
  - `UFarmSlotComponent` state VFX;
  - `ASwitchableTrap`, `ASaplingBase`, `ALightSourceBase`, `ADelayedDamage`, `AFireSpirit`/`UFireSpiritGameplayEffectInstance`, `UStationUpgradeComponent.NearbyCandidates`, `UAIBlockingComponent`, `APoolablePersistentVFXActor`.
  - Blueprint-only holders (e.g. BP_ScarabVolume) log "Accessed None" instead of crashing.
  - A new crash whose stack has a null `this` right after an effect or VFX trigger should be checked against this list first. Then add a `fxguard.GUARDS` row (the trigger table to empty), with a live repro.
- **Search (search-before-building):**
  - Searched "UE5 nullrhi Niagara spawn null", "RequestAsyncLoad null assets" and "CanEverRender Niagara": nothing documents this exact crash.
  - The `RequestAsyncLoad() called with empty or only null assets!` line comes in the same frame as the Dirty Water drinks (probably a soft-asset request of the Soulscourge status). It is not the crash: the NULL is the Niagara spawn, as the spawn test proves directly. Its origin is unverified.
  - Sources: dev.epicgames.com/documentation/unreal-engine/API/Runtime/Core/FApp/CanEverRender; docs.unrealengine.com/4.27/en-US/API/Plugins/Niagara/UNiagaraFunctionLibrary/SpawnSystemAttached; dev.epicgames.com/documentation/unreal-engine/API/Plugins/Niagara/FNiagaraWorldManager/ShouldPreCull; noesisengine.com/bugs/view.php?id=4987 (another NullRHI crash for want of a CanEverRender/GUsingNullRHI check).

## Creature spawns, power level and quest objectives for the GOAL draft cases (2026-10-26 ~19:50–20:10 UTC, dev server build 26161880, client 26162923, ClaudeDev in Temple Woods; live checks `tools/live_checks/pin_*.json`, evidence in `logs/live_queue/2026-10-26.jsonl`)
- **Asset paths offline:** the server's IoStore directory index (`RSDragonwilds-WindowsServer.utoc`) is plaintext and lists all 74 076 packages. `tools/utoc_list.py <utoc> --grep ... --game-paths` prints `/Game/...X.X_C` paths (Content/ = /Game/). There is NO `BP_AI_DireWolf_Character` and no *Thug* AI class.
- **Spawned creature classes (verified, loaded by the bench spawn fixture, `GetClass():GetFullName()` read back, AIName):**
  - Dire Wolf = `/Game/Gameplay/AI/Wolf/WolfEliteVariant/BP_AI_WolfElite_Character.BP_AI_WolfElite_Character_C`
  - Wolf = `/Game/Gameplay/AI/Wolf/BP_AI_Wolf_Character.BP_AI_Wolf_Character_C`
  - Goblin Runt = `/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/RuntGoblinVariant/BP_AI_RuntGoblin_Character.BP_AI_RuntGoblin_Character_C`
  - Terrorbird = `/Game/Gameplay/AI/Terrorbird/BP_AI_Terrorbird_Character.BP_AI_Terrorbird_Character_C`
  - Ram = `/Game/Gameplay/AI/Ram/BP_AI_Ram_Character.BP_AI_Ram_Character_C`
  - Garou Berserker = `/Game/Gameplay/AI/BeastFaction/MediumBeast/BP_AI_MediumBeast_Character.BP_AI_MediumBeast_Character_C`; Garou Hunter = `.../BeastFaction/RangedBeast/BP_AI_RangedBeast_Character.BP_AI_RangedBeast_Character_C`
- **Power level of a spawned creature comes from neither the class nor the region:** a plain `World:SpawnActor` is always PL 1 (`PowerLevel` = `GetAIPowerLevel()` = 1, damage multiplier 1.0), in Temple Woods (PL 1) AND in Bramblemead Valley (PL 2, `pin_pl2_region_spawn`). PL1 HP: Dire Wolf 240, Wolf 60, Runt 60, Terrorbird 60, Ram 50, Garou Berserker 90, Garou Hunter 80. Natural spawners pass the level in `FAISpawnInfo.PowerLevel` (`ADominionAICharacter.SpawnInfo`, dump).
- **Spawn at a power level (verified):** `GameplayStatics:BeginDeferredActorSpawnFromClass(ctx, cls, {Translation, Rotation, Scale3D}, 1, nil, 0)` → write `SpawnInfo.PowerLevel` and `PowerLevel` → `FinishSpawningActor(actor, xf, 0)` (the same two calls UE4SS's own `World:SpawnActor` makes, docs.ue4ss.com UWorld). At 3: Dire Wolf 780 HP (wiki PL3: 780), Runt 195 HP (wiki PL3: 195), damage multiplier 1.6, the client census reads PL 3. Now the bench spawn fixture's `power_level` option (pending judge patch).
- **Cleanup without destroy:** `HealthComponent:DecreaseHealth(hp + 1, ctx)` kills a spawned creature through the game's own health path (no unpossess of an AI pawn); a dead Runt's corpse is gone a few seconds later. `mod/experiments/bench_creatures.lua` (read / kill / regions / spawn_pl, dev only) + the live queue's new `server` step and `cleanup` list.
- **Regions (BP_MapRegion_C.PowerLevel):** Temple Woods 1, Bramblemead Valley 2, Whispering Swamp 2, Fractured Plains 3, Bloodblight Swamp 3, Stormtouched Highlands 4, ... (31 regions). The dev world has one lodestone (Temple Woods).
- **Quest objectives (asset data, `client_mod/commands/quest_objectives.lua` → `client_io/out/quest_objectives.json`):** objective keys are FNames that are sometimes words ("Claim a bed") and sometimes numbered ("Objective2", "DR_Main_Objective_4_3"); `brain.situation.tokens` drops digits, so a `quest_step {step}` on a numbered key would match every objective of that quest. Dragon Slayer: 1 `Claim a bed` ("Construct a base of operations in Bramblemead village. Build a shelter and claim a bed."), 2 `Return to the Wise old man after claimed bed`, 3 `Find and hunt a deer`, ... 10 `Challenge Velgar`, 11 `Return to the Wise old man after killing velgar`. On ClaudeDev: First Steps given at Objective2, Shrimp Catcher given at SpeakToWom, the rest ungiven.
# Recovery evidence — 2026-10-26

- The late places dump contains hierarchical game tags for all 31 regions. Regenerating with tools.build_places replaces fallback province inference with game-tag provenance in data/places_26161880.json. Historical notes saying tags are unavailable are superseded by this dump.
- LiveAgent.handle_event routes CommandReceived through the same addressed-chat parser. A direct diagnostic injection without a companion prefix is ignored; the recovery survival run therefore made zero model calls. It is not evidence of autonomous survival behavior.

## Gathering evidence contract (2026-10-27)

- Offline negative control confirms a selected gather profile may collect existing loose drops with inventory gain and zero swings/hits/breaks. Profile selection and expected training are capability metadata, not observations of tree felling or XP. Keep operation-specific proof independent of inventory count. Optional mode now reaches actual Controller validation and learned-skill expansion; full regression1069/1 skipped. Live effect remains to be measured.

## Candidate and transport boundary observations (2026-10-27)

- Lua harness location alone does not isolate nested module loads: gather.lua reads DW_CLIENT_ROOT and otherwise loads C:/gameserver/mod/body/util.lua. Instrumented real loadfile rejected that runtime path; inherited candidate root selected the candidate util and109 assertions passed. Test root must propagate through subprocess environment.
- Live body accepts gather mode=chop and, without an axe, truthfully returns wrong_tool/no_tool. The Python adapter failure occurred before any command reached it; typed schema validation alone was insufficient transport coverage. Native FX enchant regression20261027-212908 passed with directed preparation, not autonomous choice.

## Worktree bootstrap requirements verified (2026-10-27)

- Short unique TMP/TEMP prevents reproduced Windows path-length failure at271-character snapshot destinations. Wiki is an independent allowlisted snapshot with SQLite read-only-source backup; source hashes unchanged. Candidate dump signatures need Dominion.hpp/Dominion_enums.hpp (2.39MB), exact copies SHA checked.
- Raw state-snapshot manifest bytes enter frozen case hashes; Git EOL normalization changed those hashes in the fresh checkout. Preserve exact approved deployed bytes and verify unchanged index blobs/empty judge diff; do not repin. Candidate root now reaches nested Lua modules. Python-only publication may retain the client only when no loaded body/server file changes and pre/post byte checks agree.

## a124 live no-axe evidence and calibration limits (2026-10-27)

- A rememberedgravegoal atZ-75.18 andreturnedpositionZ-45.74 hadhorizontaldistance1.32m; two2D-onlychecksdeclaredarrival. KillZVolume fatal event anddeath/reviveindependentlyrecorded, notproofexactfalltrajectory. Respawnexplainswhyhealth100afterwards cannotcountasrecovery. Grave-lootedlogs didnotcompleteWoodcuttingXP+1 task.
- DirectorhourlyadmissionreservesMAX_REQUESTS5; count9/12 meanswaitingdespite3unusedslots. Hardnewcallwrappersanddailyspendcaps areseparate; preserveexistingwindow.
- Nativecategorymetadata ispresentinrecipeJSON but absentfromgeneratedLua catalog; genericcategorycandidateexposure isdata-driven, notsynonymmapping. Recipepresence isnotliveunlock/craftproof.
- Calibrationatcurrentrespawnarea sampled16floors,55cmvariation,guardlimit30cm; truthfullyrefused. No actualjumpmeasurementornewenvelopewritten. Queue20261027-220906 rawfailedverdict preserved.

### Water collection and reflex competition, developer-driven528ae99 (2026-10-28)

Queue20261028-005549 collected one Dirty Water in12.4s of check time, native inventory+1, shore point[52.21,1805.74,-30.87], source2108496385. Successful main-channel reflex_use ts1793145368 then consumed that item; the later recipes/craft check honestly reported missing_input0. No supply grants, model calls or reflex disabling. This proves the existing collection path and observed reflex consumption under these conditions, not an unaided food-water-rest chain or guaranteed boiling. Private queue results retain exact native IDs/state.

### Native single/double envelope and water processing on528ae99 (2026-10-28)

R10 nine-trial calibration and separate runtime-reader check passed on ClaudeDev/build26162923: single179cm; double minimum322cm at0.40s; saved1.64m/3.07m with existing margin and verified per-field provenance. Actual dry-site full guard passed; its >=12-of16 floor-hit requirement must not be called all16verified. HP100 retained. Typed traversal/Windstep remain unproved. Private r10-positive-calibration-result-20261028.json and r10-envelope-direct-read-result-20261028.json contain exact trials/state.

Developer collect6->boil1 used actual water inputs and1carriedAsh at existing Campfire, produced1CleanWater and CookingXP107->108. Main-channel successful reflex_use1793145682 then drank the CleanWater. No grant, memory reset or API call; this is developer composition plus body reflex, not unaided model completion.

### Grave-directed KillZ and natural revive on a388437 (2026-10-28)

FatalDamageInfo namedKillZVolume at00:26:58, independentclientmodeDead and healthdeath followed, then nativeGameplay/reviveHP100 at00:27:05. The target `my_grave:1793134678` was a remembereddeathposition, not independentlyverifiedcurrentgravestone; a later serverSpawnActor warning is a failedattempt, not proof of finalgraveposition. Freshreadshowsalive/samepawn at[66.15,1873.93,-34.71], runesretained/axeabsent and actualownedgraveAshRod1 elsewhere. Lastlocalsampledendpoint/straightsteering and rapiddescentdo notestablishwhetherterrain/streaming/collisioncausedentry. No fixture, restore or guessedrespawnUFunction was used. Preserve nativeworldlearning andlastdeath; privateaudit retains authoritativeevents/source/primarysearches.

### Stationary support baseline after revival (2026-10-28, source6da33fe)

Read-only queue014058 observed current dry site[65.02,1874.58,-35.15]: mode1/depth0, centre Z-3514.60cm and downward impact Z-3606.75cm, capsule half-height88cm, MaxStepHeight45cm, WalkableFloorAngle45.5deg. Reported penetration=true is ambiguous, not permission to move or evidence of the fatal geometry. Two side rays with profileCustom matched Visibility here (94/112cm), so do not generalize earlier Custom failures to every trace or assume general validity from this match. No input, health change or envelope write. Raw r26-floor-baseline-result-20261028.json retains exact output; safe step/drop/braking evidence is still required before a forward-support guard.


### Mask-aware floor observation (2026-10-28)

At one stationary current position, typed K2_FindFloor posthook output matched CurrentFloor including bLineTrace=false and HitResult.bStartPenetrating=false. The output-table copier instead produced true for both, explained by the installed UE4SS source's unmasked GetNonTrivialLocal Boolean branch. Treat ALL copied packed flags as unknown; historical Distance==0 advice does not certify penetration/support. One native registration is now dormant without subscribers until client restart; never unregister or blindly repeat the one-shot probe. This is current-position compatibility only. See [evidence, source and unresolved limits](research/r26-floor-observations-20261028.md).

Native snapshot-only adapter independently read CurrentFloor,34/88cmcapsule, zero actor/CMCvelocity, mode1/dry/grounded and actual survival values in queue20261028-022558. Namespace dev/sourcejoined is a label backed separately by external target guard. World clock is labeled as such; runtime sampler wiring refused. One stationary sample does not prove cross-sample identity, moving velocity or safe stopping.

### One-input native diagnostic (2026-10-28)

One AddMovementInput call movedY+1.392664cm/Z-0.116089cm; four post-release samples were stationary with zero actor/CMC velocity, HP100 unchanged. Own cleanup was acknowledged and the slot freed. Requested50ms callbacks actually spanned66.67-120.96ms. This does not prove full-speed braking or exact engine input timing; the pilot predates the new113-check release-velocity fields. See [R26 observations](research/r26-floor-observations-20261028.md) for provenance and limits.

### Walking-speed release and typed source reader (2026-10-28)

The staged12-input walking trial recorded450cm/s actor/CMC release velocity and7.399cm horizontal post-release travel; velocity was0 by the third roughly33ms sample, HP100 unchanged, exact cleanup acknowledged. This is one slope trial, not a universal stopping bound or sprint evidence. The standalone source reader passed33 fake assertions, GREEN1158/1skip and one explicit current-position read. Registration count remained15 and its own subscriber was removed; normal steering/startup never enables it. See [full provenance and limitations](research/r26-floor-observations-20261028.md).


### Friend-trial grave placement and assisted ramp climb (2026-10-28)

Read-only GameplayObjectRegistry.Gravestones exposed the guest character
owned grave at a surface location approximately46m above the remembered falling
death position. Registry owner GUID matched GetCharacterGuid. The remembered
death point is not a verified gravestone access point. Global body death memory
also exposed older DEV-character records despite isolated brain/task/navigation
state; keep that leakage as an open defect, not a successful migration.

Native fatal information identified KillZVolume for the first recorded death
and dehydration for a later death. The first exploration result reported
nothing_in_range and8legs despite several repeated trail positions and an
actual death. Those labels do not prove successful walks or a harmless stop.

Developer real movement inputs walked the loaded rubble approach from
[69.35,1867.33,-32.70] east to[76.49,1867.33,-31.13] with health100; Luis visually
confirmed reaching the top, still caught in the doorway. No actor location,
health or inventory was written. This is a positive control for physical
traversability, not an autonomous climb, exit or learned-route proof.

A separate follow snapshot steered toward a waypoint below the current feet at
almost the sameXY. Neither stale binding nor incorrect nav-data/projection is
yet established. The local planner already represents two floor layers and
provisional slope edges. Preserve the pending discriminating experiment instead
of describing absent slope/layer support as fact. Private source traces and
operator interventions remain under logs/recovery/friend-trial-20261028/.

### Processed movement input and truthful lexical controls (2026-10-29)

Actualclientread-only APawn.GetLastMovementInputVector and pendingvector getters
worked. Midramp native vectors about(0.69,-0.724,0) corresponded to observed
velocity andclimbing; this is not proof whytheinitial25cmentry stalled. Native
gametime is latchedinsidecallback: measuredforward_search.duration_s0 is not
zeroCPU/wallcost. The two recorded doorwayqueries nowreturnmatchedfalse while
AshLogs returntrue againstthe same64loadedentities, with lexicalbasis explicit.
No actualdoor absence, geometricunderstanding or autonomous taskpass follows.

### Native ground-following differs from one straight capsule chord

Actual-pose query then real input crossed the blocked segment with grounded final
state, H100, no driver jump/teleport. The same retained sampler subspan's midpoint
resolved about3.2cm above straight interpolation; left and re-resolved right full
capsule sweeps were clear. One candidate refinement produced11samples/26queries.
This supports a generic bounded terrain-following alternative, not declaring the
blocked chord clear or certifying arbitrary StepUp. Actor/component remainunknown;
unknown weak handles were not dereferenced. Privatea735/a737/a738/a740 evidence.


### Native partial route can reappear after guarded memory stall (2026-10-29)

On `ccfd357`, a812 trace shows source memory / wp1 / clear corridor, then
`guarded_stall`, then source nav with the old partial route. Memory clearing
left that dormant route available. The first stall occurs around a nearby
intermediate point with observations on both sides; sparse samples establish
oscillation but not exact per-frame friction or motor response. a810 normal
outbound succeeded without a route discard. Preserve this distinction when
choosing fixes: a failed support check after fallback does not prove the
original remembered connector is physically blocked. Evidence remains private
under logs/recovery/nct-trial-a804; research and limits are in the crossing design.


### Full model feedback led to recovery beyond the temple (2026-10-29)

On `1ba76d5` full-agent a811, Sonnet successfully researched live lodestones and
returned a complete1590-token initial ordered plan. Haiku received a blocked sweep,
explored, encountered `movement owner token required`, used stop and retried go_to,
then reached the selected lodestone about152m from the spawn landmark. Subsequent
local-route failures prevented the200m/return objective; maximum observed distance
189.4103m, health100. This is fresh full-agent behavior, not an acceptance pass.
Model requests/responses and body receipts survive in the private a811 evidence.


### Exterior blocked sweep has side-contact evidence, not the old floor chord signature (2026-10-29)

After developer a823/35d8d61, a stationary replay at recorded [226.11,1790,-34.39] used the current full player capsule/profile and typed floor queries. It reproduced blocking at refinement depths0/1/2 and both extra split halves. Impact normal was approximately[-0.8023,0.5963,-0.0264], with contact about55cm above capsule centre; supporting floor was about88cm below with upward normalZ~0.96. This strongly supports a real side obstruction rather than the earlier upward-floor-normal chord artifact. Actor identity, historical scene equality and full-route feasibility remain unknown. No guard was relaxed. The18-query probe completed with owned cleanup; private collision-analysis-a825.json records sources and limits.

Full-agent a821 later stalled at a different temple location near69m-X. Do not transfer this exterior collision explanation to that separate failure.

### Complete native route points do not certify the intervening floor profile (a828)

Actual retained native route from developer generation8 starts at feet
[8760,180527,-2998]cm and next point[13312,181024,-3030]cm. The character
walked between these XY points with health100 and clear short-horizon sampled
guard observations; at trace23 its centreZ was-3040.091cm and half-height88cm.
Its feet therefore differed by about1.17m from the straight interpolation
of those route endpoint heights. Keep sparse native route geometry distinct
from current sampled support and actual character pose. This observation
does not itself authorize dropping floor checks or changing arrival criteria.
Private evidence: lpc-trial-a819/retained-segment-a829.json and generation8
route trace in outbound-input-a828-samples.jsonl.


### 2026-10-30: physical side collisions versus unavailable route
Stationary a834 full-capsule queries at the actual a832 failure pose reproduced memory-connector side contact (normal approximately [-0.707,-0.707,0], contact 13 cm above capsule centre) and native side contact. Finer subdivisions still blocked. The long direct chord separately hit the floor; the sampled failure was a different side contact. Plain copied output flags retain their known marshalling caveat; native Boolean and consistent geometric copies support the side-contact conclusion. Sensor cleanup succeeded. A blocking segment is not proof that the original destination has no route.
- Sources opened: [FHitResult](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/FHitResult), [native StepUp](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/StepUp?application_version=5.5), [Nav2 recovery](https://docs.nav2.org/jazzy/getting_started/nav2_behavior_trees/trees/nav_to_pose_with_consistent_replanning_and_if_path_becomes_invalid/), [LazyPRM invalid-edge removal](https://ompl.kavrakilab.org/LazyPRM_8cpp_source.html). These describe semantics/patterns, not drop-in Dragonwilds APIs.
- Decision: reuse existing guarded local planning on a demonstrated blocked native segment; do not weaken collision checks or delete learned world routes. Exact queries and runtime receipts remain in private `logs/recovery/npg-trial-a832/decision-a834.json`.

### Grounded movement need not follow the straight supported chord (2026-10-30)

Actual native controls a848 stayed grounded with no jump; a850 capsule queries
accept every recorded pose but reject one interpose descending chord. At the
failed segment, horizontal then vertical-down checks both clear. Private a851
whole-segment deferred-descent comparison clears; measured wall and missing
nearby-support controls still reject. This supports a minimal trajectory-check
repair, not exact engine StepUp equivalence or general step/cliff navigation.
Fresh capsule support a853 rejects some locations proposed by line-floor scans;
a852's first drop fixture was initial overlap, not evidence of a walkable ledge.
Primary semantics: https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/MoveAlongFloor?application_version=5.5
and https://dev.epicgames.com/documentation/unreal-engine/BlueprintAPI/Collision/CapsuleTraceByProfile .
Raw evidence and search decision: private npg-trial-a832/decision-a850-a854.json.

### Distinguish later collisions from the descent mismatch (2026-10-30)

On published6cade13, developer a867 physically reached the lodestone with the
deferred-descent primitive in its crossed-waypoint trace. Later a869 records
the full failing scan before cleanup. a870 reproduces that scan exactly:
horizontal capsule collision persists at lifts2/5/15/45cm; the starting pose's
upward1cm query clears but the failed endpoint's does not. This evidence does
not justify treating every capsule block as a floor-chord artefact. A nearby
tree appears in ordinary look data, but hit actor identity is unproven.

The independent a870 waypoint audit finds near-zero motion under directional
input and no observed waypoint crossing; it does not establish a stall bug.
a872 separately captures an unwalkable floor result with normalZ0.686586 on a
partial native path. Alternative routes remain untested by those failures.
Private records contain exact geometry, limitations, queries and source links.
