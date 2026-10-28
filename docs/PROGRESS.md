# Progress log (append-only)

### Recipe visibility deployed; production intent remains unfinished (2026-10-28)

Source 72a8e37 is pushed and deployed after 1198 passed / one skipped GREEN.
All 15 frozen hashes matched; judges are unchanged; all 21 saved state files
were preserved. The Controller receives all 24 axe candidates including the
unlocked stone axe and native scoped counts. The repeat chose stone but used
the old axe after craft_plan treated owned stock as satisfying its target.
No new axe or station: the compound request still failed. Additional production
versus inventory-target semantics are a separate isolated W candidate.

A developer-selected Tempest Shield cast used 15 air runes and produced the
native shield tag and effect, health 100 and body idle. This proves casting,
not autonomous tactical selection. Spend: $0.0402 / 35 Haiku calls. Evidence:
docs/research/r26-postfix-and-shield-20261028.md.

### Combined crafting and route candidate passed the gate (2026-10-28 11:50 Berlin)

The reviewed wave passed 1198 tests with one skip in 389.34 seconds,
CHECK_ALL: GREEN. All 15 frozen file hashes matched; judges are unchanged.
It adds scoped native ingredient/output counts, consistent recipe candidate
limits and observed unlock metadata, and bounded observational route recovery.
The integration fixture was updated and re-reviewed after the first gate found
its obsolete inventory-list expectation. Publication and native/model-context
validation are next; no new crafted axe or station is claimed yet.

### Unaided tree chain verified; new-axe objective still unmet (2026-10-28)

On tested deployment `3e95e40`, Haiku answered “Can you cut down a tree?” by
checking inventory, recovering its own grave, equipping the recovered axe,
felling/splitting wood and collecting five new logs. Four calls took 42.234
seconds and cost $0.0043. Independent native evidence: Woodcutting XP 219→239,
a standing tree became a stump, and health stayed 100. The eight logs recovered
from the grave are excluded from the five freshly gathered logs. This proves
a recovery/equip/woodcutting/collection chain, not crafting or a full milestone.

The explicit follow-up “Can you make yourself a new axe, then cut down a tree?”
failed its crafting objective: four calls, 38.922 seconds, no craft call, axe
count unchanged at one, wood 13→17. Its search requested 25 candidates but got
15 of 24 matches, hiding the basic stone axe. It chose locked bronze, then used
its existing axe. Generic candidate visibility, native count and route recovery
changes passed focused tests and cold review; the combined gate is next.

Nutrition, test-scene positioning and the original private cleanup mismatch
are declared in `docs/research/r26-unaided-tree-chain-20261028.md`. Root verified
terminal processes and idle body/arbiter independently. UTC model spend is
$0.0353 across 31 Haiku calls, with no planner or unpriced calls. R remains on
`3e95e40`; W candidates are isolated until the gate and controlled publication.

### Live short-route throughput failure isolated (2026-10-28 10:35 Berlin)

Reviewed2bff707 is pushed/deployed after1197passed/1skip GREEN. First live
control refused at HP1/hydration0; declared DEV fixtures restored health100
and8Bread/8Water (R26 totals68/91), actual consumption raised hydration.
Default control then started but remained sampling:17ticks/272traces over
13.3game seconds, no movement/acquisition/jump. Timer/watchdog/idle terminal.

Actual-module instrumentation found a fresh arbiter lazily recompiles the whole
mover during every ownership check. Reusing the existing set_move(actualM)
API in a private experiment removed520nested mover compilations per160traces,
CPU4.208->0.463s, preserving510route checks/1030uncachedworld resolutions.
This is offline evidence; narrow candidate regression/review/gate/live pending.
No new autonomous capability or formal milestone is claimed.10:30deadline
slipped; revised developer10:45,Haiku11:00,verdict11:15,repeat/M1audit12:45Berlin.

### Reviewed short-route movement passed full gate (2026-10-28 10:11 Berlin)

The eight-file frozen candidate passed CHECK_ALL: GREEN: 1197 passed, one
skipped, 485.40 seconds (terminal exit 0, cf-320e06f3). All eight SHA256
hashes matched after completion; frozen judge diff remains empty. Short local
routes now require an admitted endpoint and observed jump/landing before
advancement. No physical traversal or new autonomous chain is claimed yet.
The 10:15 delivery checkpoint was met. Next: client-only publication, developer
real traversal and inventory controls, then a bounded unaided Haiku attempt.

### Real local-planner route found; movement integration underway (2026-10-28)

The bounded developer movement control followed memory instead of the local
planner and was correctly inconclusive. A separate no-input actual-LP probe
then found7points to the upper level with one157.3cm jump under the measured
164cm envelope. Endpoint~0.539mXY/0.0074mZ fromrequestedfloorpoint; no tolerance
was supplied by that probe. Position unchanged/HP100, cleanup verified,0APIcalls.
This is a planner candidate, not walked terrain or an autonomous task pass.

The isolated mover integration now addresses short local authority and actual
jump landing before advancement/learning. Focused admission checks pass; full
movement regression/cold review/gate/live validation remain before deployment.
Runtime stillb29d97b. Native evidence and limits:
docs/research/r26-short-local-planner-20261028.md. Goal check on current runtime
reports GOAL NOT MET with no counted current-hash runs; approved judges remain
unchanged. Luis requested hourly updates; the existing heartbeat is now hourly.

### Craft plan deployed; native acquisition alternatives verified (2026-10-28)

b29d97b is pushed/deployed, companioncab3d4711522f3e9/bodydcc17e2a19b68b81.
Native craft_plan now exposes3options each for basic stone/log ingredients,
preserves lower-bound/unknown counts and omits the mandatory currency list.
No provider calls; this is an information-contract improvement, not a new
unaided gameplay pass. Client-only boot48.5s, all21 statefiles unchanged during
publication; client4124/ClaudeDev, server7016/Steam3284/helper3228+1980 retained.

The bounded stationary context comparison returned identical partial paths for
nil/Default. Gigantic returned complete only after shifting start~3.1m upward
and~3.1m horizontally; it does not supply a route from the actual pawn. No mesh
switch was made. Position/HP100 unchanged, diagnostic removed, rawidle/slotfree.
Next isolate existing short typed traversal empirically before changing route
admission. Full M1-M6 goal reactivated by Luis; no autonomous chain pass yet.
See docs/research/r26-crafting-deployment-nav-context-20261028.md.

### Craft acquisition alternatives passed the full gate (2026-10-28)

The independently reviewed craft_plan wave passed1197tests/1skipped428.81s,
CHECK_ALL: GREEN (terminalsession40253; pytestlogcf-19872224/check-all.log).
All10 saved source/test/design/evidence hashes matched through the gate.
Plans expose OR acquisition alternatives and AND recipe inputs, preserve
same-snapshot count uncertainty and avoid unsupported readiness/craft claims.
Actual native craft execution gates and frozen judges are unchanged. Client-only
publication and fresh native response validation are next. Legacy recipes and
craftable assessment remain a separate count-uncertainty gap.

Developer live controls made one short slope arrival, followed by a partial
upper approach and another failed loose-stone acquisition from the new start.
Health100, no observed resource gain; no autonomous capability pass. Latest
position~[81.7451,1872.1527,-34.8831]. Nutrition support totals52Bread/77Water,
API day unchanged$0.0259/23Haiku. A bounded private nav-context comparison is
being reviewed to discriminate mesh selection from local graph disconnection.

### Model view deployed; next prerequisite defects measured (2026-10-28)

Source9cacd96 is pushed/deployed after1197passed/1skipped CHECK_ALL: GREEN.
Fresh native inventory through the actual Controller/FakeLLM path measured
12963->1724UTF8bytes, preserving raw/enriched/positive/unknown evidence and
ToolCallID, zero provider calls. The subsequent bounded natural tree trial used
6Haiku/0planner,21.375s,$0.005 and consulted craft_plan, but did not craft or
fell a tree. It did not call inventory, so no behavioral compaction effect is
claimed. HP100/XP219 held; strict initial axe absence remains unknown.

The graph flattened one catalog acquisition into mandatory42currency while
hiding gather options; it also discarded inventory completeness. A generic
alternatives/uncertainty design passed independent conditional review and is
being implemented in isolation. Separately the tested runtime ran one queued
developer loose-stone pickup: path_blocked after3target attempts, gathered0,
HP100, no observed inventory gain. This new live evidence directs a parallel
navigation diagnosis, not another identical Haiku retry. Queue terminal/slot
free; nutrition totals46Bread/71Water. Day spend$0.0259/23Haiku,0unpriced.
See docs/research/r26-model-gap-native-retry-20261028.md. M1-M6 remain unmet.

### Model gap-summary candidate GREEN (2026-10-28)

Full gate1197passed/1skipped417.84s, CHECK_ALL: GREEN,
logs/recovery/cf-a529e3d4/check-all.log. All8 saved file hashes matched before/
after. Independent review approved full raw/enriched preservation and the copied
model view. Actual recorded inventory message13068->1929UTF8bytes, with exact
gap counts and positive/unknown facts. Publish Python-only code, then developer
native read-to-view validation and one bounded model measurement; no behavioral
success or strict no-axe baseline is claimed from this offline checkpoint.

### Natural retry survived; repeated model diagnostics targeted (2026-10-28)

The exact natural tree request on deployed50111a7 used6Haiku controller calls,
0planner,45.766s and$0.0084. The grave move was rejected by the actual v2 no_path
reply; HP100, no tree/axe/resource or Woodcutting XP gain. The model asked for a
spare hatchet rather than use available crafting/research tools. Strict no-axe
absence remains unknown; declared nutrition totals42Bread/63Water. UTC total
$0.0209/17Haiku,0Sonnet/unpriced. Original failed private cleanup result is kept;
root separately verified processes gone and raw body/arbiter idle before release.

The next reviewed candidate compacts repeated read_status gaps only in a copied
model result. Raw logs, full enriched inventory and positive/unknown evidence
are retained. Actual recorded message replay:13068->1929UTF8bytes;50 focused
tests passed. No provider token or decision improvement is claimed. Fresh VM_READ
handle access for client1416 was denied(error5); native empty verification is
parked without blocking this independent work. See
docs/research/r26-tree-retry-20261028.md. Full gate/publication still pending.

### Route authority deployed and checked through the real client (2026-10-28)

Source50111a7 is pushed/deployed, companion8b196d3efadaabdc and
body023b06997f5e31de, clean code and unchanged judges. Full gate1192passed,
1skipped427.07s GREEN. All21 preserved files were unchanged during disk
publication. Server7016/Steam3284 retained; client1416, helper3228/1980 and
watchdog12580 adopted. The real server experiment copy matches tested bytes.

Developer negative sameXY+50mZ failed truthfully with no_path and no observed
displacement/health loss. The configuration-assisted2m required positive
arrived through a matched v2 route, moving1.8m within0.4m tolerance. Exact1000cm
threshold restoration and idle cleanup independently verified before release.
Neither is an unaided or default long-trip pass. Native step times2.5s and3.8s
including positive cleanup; no game-model calls. The next recovery task is the
capped natural tree test. See docs/research/r26-route-controls-20261028.md.

### Owned route admission passed the full gate (2026-10-28)

The independently reviewed route-authority wave passed **1,192 tests,1 skipped,
427.07s, CHECK_ALL: GREEN** (`cf-d8781fb6/check-all.log`), with all14 saved
file hashes unchanged through the gate. It holds required long trips without
owned route evidence, preserves typed unknown metadata, binds one-use requests
to the current movement/world/owner, reports route failures truthfully and keeps
follow persistent. Accepted traversal finishes before the next authority
boundary. Cold review fixed a real Python/Lua UUID mismatch and reentrant owner
checks; actual producer/consumer and focused movement regressions now run in the
normal gate. No judge changes. Runtime publication and benign native controls
are next; this offline checkpoint is not a no-axe/tree or milestone pass.

### Stationary navigation contrast and isolated candidate work (2026-10-28)

On deployed83f0ce3, the reserved developer query to the character's XY+50mZ
returned no_path/zero points; the nearby2m contrast returned two points and a
2.02m route. Position stayed identical and HP100; no movement/model calls.
These are observations, not autonomous passes. The two registered checks are
terminal and their private registrations archived. Native-active durations:
17.6s declared nutrition setup and2.1s stationary navigation; further travel
awaits review/gating/publication of the actual route-authority candidate.

The DEV reflex consumed declared harness supplies through real input. R26
nutrition totals40Bread/59CleanWater. API spend remains$0.0125/11Haiku calls,
no Sonnet/unpriced calls. Separate file owners are implementing helper protocol
and movement admission; helper metadata/lifecycle cold review passed after an
overflow regression. Candidate work remains isolated from the running client.
See docs/research/r26-route-controls-20261028.md. No axe/tree or M1-M6 pass.

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


### Natural tree-task pilot failed; no-path fallback confirmed (2026-10-28)

Five Haiku controller/zero planner calls ($0.0052, UTC total$0.0125/11calls)
selected inventory then a remembered grave containing an axe. Actual target
`[88.74,1675.65,-101.47]`; repeated oracle no_path/zero-point replies and
exhausted local segments still led to straight sprinting. Native KillZ death
04:31:52Z; revival04:31:59Z. No tree/axe crafting, no no-axe recovery proof.
Manual cancellation was late, after death/action completion; the timer did not
prevent it. No repeat of this route before the generic authority fix. Driver
exited1 on dead cleanup; root separately verified terminal process, fresh
DEV/samepawn/HP100/idle after respawn and released the slot. Full trace, failed
result and changed per-world memory retained, no restore/reset. Details:
docs/research/r26-tree-pilot-20261028.md. Current position
`[63.152076661332,1875.5658766807,-35.446093180758]`, old flat operators stale.

Inventory perception source is independently reviewed and isolated in W; full
gatecf-84ece854 was RED only on a legacy wording assertion (1167passed/1skip).
That test now preserves its food/grave/action checks and requires the intended
unknown/lower-bound wording; focused test passed. New full gate is running
via logs/recovery/inventory-read-active-full-gate.txt. Do not relabel the old
red run or deploy the candidate before the new gate is GREEN. Count-sensitive
action verification, native empty representation and frozen judges remain
unchanged/unproven by this perception wave. Original goal ACTIVE/unmet.


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


### Jump ownership published; native confirmation pending

Sourcec145862 is pushed/deployed on newDEV client10824 after51.1s client-only restart. Server7016/Steam3284 retained, runtime source digests matched, all21 backed-up state files unchanged and approved judges untouched. Companion9b93dd8d5b1eed87/body6f10d817633533e5. Fresh local rearward100/150/200cm native floor observations succeeded.4Bread/8CleanWater plus real consumption healed HP1->100 (R26 total18/29), no autonomous survival credit. Supervised movement check awaits corrected runner rereview. Candidate floor lifecycle remains isolated in W:56 actual-hub fake checks/5 design tests, cold review/full gate pending.


### Jump ownership published; native confirmation pending

Sourcec145862 is pushed and deployed on newDEV client10824 after a51.1s client-only restart. Server/Steam retained, runtime source digests matched, all21 backed-up state files unchanged and judges untouched. Companion9b93dd8d5b1eed87/body6f10d817633533e5. Fresh local runout observations succeeded;4Bread/8CleanWater plus actual consumption healed HP1->100 (R26 total18/29), no autonomous survival credit. Supervised move/jump check awaits the corrected runner review; floor lifecycle candidate stays isolated in W.


## 2026-10-28: jump ownership checkpoint, publication pending

Frozen movement/arbiter changes bind Jump/StopJumping and caller progress to the exact movement generation, token, controller, pawn and life. Arbiter transitions provide a scoped stop context; cleanup and route-memory callbacks revalidate ownership. A failed native call cannot consume jump progress, and accepted intent remains distinct from observed flight. Arrival success still persists in per-world navigation memory. Independent design/code reviews approved; focused design/move/arbiter tests passed6, and full gate `logs/recovery/cf-a810de39/check-all.log` is TERMINAL GREEN:1158 passed/1 skipped in378.82s. This is not a floor-support guard or a live jump pass.

Three developer flat walking repetitions on preceding deployed source0a1590d reached450cm/s with7.5254,6.9539,7.3936cm horizontal post-release drift; all observed stable, HP100 and owned cleanup acknowledged. These are local walking measurements, not sprint/terrain-wide stopping bounds. Setup used a declared DEV teleport and4Bread/8CleanWater; total R26 supplied14Bread/21CleanWater. No health/physics writes, no autonomous credit. Original no-axe chain and M1-M6 remain unmet.

Root now owns client-off publication and supervised walk/one jump verification; a bounded Terra design worker and independent reviewer work in parallel. No duplicate client or game-model brain. Development allowance32% weekly used; zero new game-model API calls, last UTC-day spend$0.0073/10 across6Haiku/0Sonnet.


## 2026-10-25 â€” Session 1

- Toolchain: Git 2.56.0 and Python 3.12.10 installed via winget (`--source winget`; the msstore source fails with a certificate error on this VM). The session runs elevated (admin: True).
- Repo initialised at `C:\gameserver` with the CLAUDE.md section 12 layout.
- Luis approved subagents and parallel work (this overrides CLAUDE.md section 2's single-session rule).
- Parallel subagents ran for: Track M (brain), UE4SS/chat/bridge research, the Lua bridge body, Phase 4 body research, and the two dump analyses.
- **Server (Phase 1 build steps done):** SteamCMD (winget) installed build 26161880 into `C:\GameServers\Dragonwilds`.
  - The server needed the VC++ 2015â€“2022 runtime; without it, it hangs with no log.
  - `DedicatedServer.ini` has Luis's OwnerId, world `CompanionDev` and a world password (in `server-secrets.local.txt`, not in git).
  - UDP 7777 and 8888 (beacon) are open. The EOS session is created and advertised.
  - Scripts are in `tools/`.
- **UE4SS works on the dedicated server (Phase 2 build steps done):**
  - UE4SS's own proxy can't load here: it is a dwmapi proxy, and renamed to version.dll it lacks the exports the server needs, so the server hangs.
  - Fixed with Ultimate ASI Loader as `version.dll`, loading `ue4ss\UE4SS.dll`.
  - The DWCompanion mod loads, logs JSONL to `logs/mod/`, and registers its hooks.
  - Headless dumps are generated by `mod/scripts/dumper.lua` (with `dump.flag`) and copied to `dumps/26161880/` (gitignored).
- **Bridge:** `mod/scripts/bridge.lua` runs inside the live server. Python `BridgeClient` pinged it 10 times: median 166 ms, max 187 ms (the poll interval is 150 ms). The in-game `!ping` gate is still open: it needs chat hooks and Luis.
- **Track M:** 38 tests pass (`.\.venv\Scripts\python.exe -m pytest tests -q`), including the Lua bridge tests (Lua 5.4.5). Evals are written but have not been run, so no API spend.
- Windows Update: active hours 08â€“02, no auto-reboot while a user is logged on.
- **PHASE 1 GATE PASSED (2026-10-25 12:18 UTC):** Luis joined `CompanionDev` from GeForce Now. Server log: `Login request ... Name=luisdeburnaybastos userId: RedpointEOS:...`, then `Join succeeded: luisdeburnaybastos`. GFN can reach a self-hosted server.
  - The `PlayerController:ClientRestart` hook did not fire on join; Dragonwilds' spawn and possession path differs, so hooks will be based on the dump.
- **PHASE 2 GATE PASSED (12:23 UTC):** the mod logs at start, the dump is generated and searchable, and the item-pickup hooks logged functions with parameters while Luis picked up sticks.
  - **Text chat exists and is readable.** `!ping hello` arrived in Python as a `command_received` event over the bridge.
  - The other half of the `!ping` gate, the reply appearing in game, needs a "say" implementation (task P5.3).
  - Tree felling and inventory adds aren't hookable (task P2.6); they will be verified by polling state.
- `/simplify` pass done, using 4 review agents and 2 fix agents:
  - Python: shared protocol envelopes, reason classification moved into `Reason`, injectable SkillRegistry, dead code removed.
  - Lua: dkjson 2.8 replaces the rxi json.lua null/{} hack, one sanitiser, the log handle stays open.
  - 39 tests pass, and the Lua tests can no longer skip silently. The refactored mod was redeployed and verified on the live server (14 hooks, ping OK).
- Added a `debug_run` hot-reload trigger and `tools/bridge_cmd.py`. Phase 4 experiments can now run while Luis is connected, without restarts.
- Phase 4 dump analysis: humanoid NPCs are plain Actors and can't walk. The body will be a `DominionAICharacter` creature. The game has a native `FollowerComponent:ToggleFollower` (the Kalphite summon), so we try that first.

### Next session: Needs Luis (in order)
1. **Phase 4, T2: native follower.** Luis joins and stands in the open. Claude runs `debug_run follower_test {action:"status"}`, then `{action:"summon"}`. Ask: did a Kalphite appear, and does it follow you? Then: leave and rejoin; is it still there and consistent? That is the gate.
2. If T2 fails, **T3: confuse.** Luis goes near any creature, and Claude runs `{action:"confuse"}`. Ask: does it start following you?
3. Further fallbacks are T4 (`AsyncDomSpawnAIAtLocation`) and T5 (raw `SpawnActor` plus `MoveTo`), following the plan in `docs/research/2026-10-25-dump-body.md`.
4. **Phase 3 gate:** teleport Luis with `K2_TeleportTo`, or give him a single harmless item with `InventoryComponent:AddItemByData`, then confirm it survives a rejoin. Luis's character profile is client-owned, so this also tests persistence. Use harmless items only, because the profile travels to the group's real world.
5. **Phase 5 `!ping` gate:** implement companion "say" (task P5.3) and test that the reply shows in chat.

### Blocked
- Nothing is blocked. Remaining work needs Luis in game, plus a decision later on model provider and API key for Phase 6.
- **PHASE 4 GATE PASSED, as CLAUDE.md words it (12:46 UTC):**
  - `ToggleFollower(DA_Kalphite_Friend)` spawned a Kalphite on Luis's GFN client. It followed for a while, then stalled.
  - `DominionAICharacter:Confuse(pawn, true)` on a wild Kebbit made it follow and keep up over 30â€“40 m.
  - The follow does not survive a rejoin, so a body reflex (`mod/scripts/companion.lua`, checking every 5 s) re-recruits a Kebbit or deer within 60 m. Luis rejoined and a Kebbit was following him again.
- **Goal clarified by Luis:** the companion must be a HUMANOID that acts like another player: switch weapons, kill enemies, pick up loot, talk, in real time. A following animal proves the mechanism but is not the body.
  - New task P4.H. Two research agents launched: dump analysis of player-pawn dependencies and factions, and web research on player-like bots in UE.
- Fixed: `debug_run` now loads modules with `loadfile`. `package.loaded` + `require` did not pick up redeployed files under UE4SS.
- Written down so nothing is lost: `docs/research/2026-10-25-voice-discord.md` (Discord voice and realtime-voice research) and `docs/research/2026-10-25-humanoid-goal-and-routes.md` (clarified goal, three routes, experiment order). Route 1 experiment module: `mod/scripts/puppet_test.lua`.
- **Route 1 milestones with Luis (13:00â€“13:10 UTC):** spawn, possess, walk (done). Dressed in Luis's Zamorak set and skillcape, holding a Skullsplitter (done). Swung at a Kebbit and did damage, the Kebbit fought back, and the puppet stayed immortal (done).
- The "freezes" turned out to be crashes behind UE4SS's blocking MessageBox. Root causes found from dumps with cdb. The watchdog now auto-restarts the server. See DISCOVERIES "ROOT CAUSES".
- Design for crash-proofing and the item catalog: `docs/design/robustness-and-item-catalog.md`. An agent is building `mod/scripts/catalog.lua` and `tools/build_catalog.py`.
- **Model API configured (2026-10-25):** `ANTHROPIC_API_KEY`, `DW_CONTROLLER_MODEL=anthropic/claude-haiku-5-5` and `DW_PLANNER_MODEL=anthropic/claude-sonnet-5-5` are set as **user environment variables** on the VM. They are not in any file and not in git (`git grep sk-ant-` is clean).
  - Smoke test: 1 Haiku call via LiteLLM, 19 tokens in / 5 out, 3.1 s including cold connection setup.
  - Luis pasted the key in chat and accepted the risk. Recommended: rotate it in the Anthropic console and set a monthly spend cap.
- Brain live loop done (`python -m brain.run_live [--dry-run]`, `python -m brain.tail_logs`). 51 tests pass.
- **PHASE 6 GATE PASSED (2026-10-25, about 13:52 UTC, Luis via GFN):** `!c follow me`, `!c stop` / `wait here`, `!c come here` and `!c kill that kebbit` all worked from chat. Claude Haiku 5.5 was the Controller; the server-driven player puppet was the body.
  - The kill was verified from game state: `killed: true`, 4 swings.
  - Fixes on the way:
    - installed `mcp`, which litellm needs when tools are passed;
    - dropped `temperature`, which the API has rejected since 2026-10-21;
    - raised `max_tokens` to leave room for thinking;
    - set `parallel_tool_calls=False` plus a one-action rule, because the model was pairing follow with stop.
  - Gaps Luis noticed:
    - Attacks only use the first swing of a combo, and use the sword set while holding a mace. Next: real combo chains from the catalog, plus specials.
    - The overhead name still reads "Character Name Here".
    - Speech works only via the relay.

### 2026-10-25: catalog run and melee combos (task P7.C1, in progress)
- **Catalog:** ran it live, staged, with no crash: `data/items_26161880.json` holds 466 items. It now records swing timing from the montage notifies (`--notifies`), and tools no longer count as "magic" weapons.
- **Generator:** `tools/gen_attack_data.py` produces `mod/body/attack_data.lua` (81 melee items, 26 sets).
- **Attack loop rewritten:** `mod/body/combat.lua` is a reactive behaviour tree on vendored beehive.lua (MIT).
  - It uses the held weapon's chain (Skullsplitter: Club 1â†’5) and issues each step at that step's input-window end.
  - It resets the chain after the finisher or after a long gap, and uses the weapon special between combos when charged.
  - It has `on_tick`/`evade`/`before_swing`/`after_swing` hooks for spells.
  - `skills.lua` keeps the handler contract.
- **Tests:** 30/30 Lua body tests and 56 pytest pass.
- **Next:** a server restart (skills.lua loads at startup), then Luis's in-game check: the mace chains and uses the special.

### 2026-10-25: spells wired + reflex rules (tasks P7.S1, P7.R1, P7.R2, in progress)
- **Body:** `main.lua` registers the spells service and the new `mod/body/rules.lua` in one block. Rules go first in the combat `on_tick` hooks, then the spells reflexes (shield on low HP or a telegraph, Windstep on 3+ clustered enemies).
  - Each reflex is gated by the catalog's verified-in-game route status. Both are off today; `DW_SPELLS_UNVERIFIED=1` turns them on.
  - Cost policy is `mirror_budget` (falls back to `mirror` if the inventory store isn't ready). Luis's unlocks are read live from his PC, with the catalog snapshot as the fallback.
  - The rules engine is also new: it holds sensable triggers only, per-enemy persistence in the bot state, and the handlers `set_reflex_rule`, `list_rules` and `clear_rule`.
- **Brain:**
  - New `cast` tool and the reasons `on_cooldown` (the executor waits up to 5 s), `not_unlocked`, `unsafe` and `cant_sense`.
  - The Controller's context carries `castable_spells` (`brain/spells.py`) and `reflex_rules`. The rule tools are offered to the Controller, with unsensable triggers refused before reaching the body.
  - New mock spells/rules, plus BridgeClient methods and protocol docs.
- **Tests:** `mod/tests/test_rules.lua` (13), `test_spells.lua` (36), `tests/test_spells_rules_brain.py` (20). Full pytest: 113 passed. Lua: body 30/30, core 16/16, bridge 14/14.
- **Live (no restart needed, already loaded at the 15:45 restart):** the handlers and persistence work. The telegraph sensor read is still unverified (nobody online).
- **Next:** Luis tests `!c every time the kalphite raises its claws, windstep away`, then a Kalphite fight. Run `rules_probe watch` during the fight to verify the attack-state poll.

### 2026-10-25: sleep skill, night-skip valve, first cast canary (tasks P7.Z1, P7.S1, P7.S2)
- **Sleep:** `mod/body/sleep.lua`, wired in `main.lua` and live since the 16:32 restart.
  - Handlers: `sleep`, `wake`, `sleep_status`, `night_skip`.
  - Reflex: when Luis sleeps, the bot sleeps (in a free bed within 25 m, else via the rest flag); when he wakes, the bot wakes and follows him again.
  - The brain has `sleep`/`wake` tools.
  - Which flag lets the night pass is pending a night test with Luis.
- **Cast canary:** Fire Spirit was cast on the puppet through `self_effect`, 14 m from Luis. The GE instance replicated with no crash. Waiting on Luis's visual check before setting the verified flag. Tempest Shield is gated by its own test (`needs_own_test`).
- **Woodcutting:** `spells.woodcutting_assist(p, sit)` decides Trunk Totem / Splinter / Axtral Projection for gather.lua to call. It is not castable yet (module-graph spells, no route).
- **Tests:** `test_sleep.lua` (9), `test_spells.lua` (38), `test_rules.lua` (13), and brain sleep tests.
- **Sleep productised** after the main session's live proof: shelter spawn plus direct Sleep, direct Sleep for beds from about 3 m, the reflex on Luis's rest state, the shelter removed on wake. The spectator valve and the rest flag are gone. Needs a server restart to load. `test_sleep.lua` 9/9.

### 2026-10-25: crafting, strict emulation (task P7.3)
- **Recipe catalog from live game data:** `mod/scripts/recipe_dump.lua` (read-only, staged) + `tools/build_recipes.py` -> `data/recipes_26161880.json` (1232 recipes, 45 station types of which 25 have a loaded actor class and recipes, 1081 items, Luis's 827 unlocked recipes) and the generated `mod/body/recipe_data.lua`. Wiki Bucket cross-check: 619/739 exact matches; Iron Bar = 3 Iron Ore or 9 Iron Salvage Pile at the Furnace, as on the wiki. Recipes added to `patch_pipeline catalog-diff` and the patch runbook.
- **`mod/body/crafting.lua`:** strict emulation (inputs held, live station of the right type within interaction range, recipe in Luis's live `RecipesUnlocked`; exact consumption incl. fuel at processing stations, craft-time wait, exact outputs as instances, refunds on interrupt). Handlers `craft` (async), `craft_check`, `recipes`, `stations`; wired in `main.lua` (CRAFTING block, effective at the next restart). Protocol in `brain/BRIDGE_PROTOCOL.md` ("Crafting"); brain integration is the brain agent's.
- **Drift check:** `mod/experiments/craft_drift.lua` + `tools/craft_drift.py run` (records one real craft by Luis, read-only, and compares with `crafting.plan`).
- **Tests:** `mod/tests/test_crafting.lua` (21), `tests/test_recipes.py` (9), `tests/test_lua_crafting.py`; full suite green.
- **Live:** extraction ran with Luis online, no crash (dumps 10). `craft_drift check` read Luis's unlocks live (827), the bot's store, and found **no station in the dev world**.
- **Next:** restart (announced) so `main.lua` registers the handlers; Luis builds a Crafting Table (and later a Furnace + Kiln for charcoal) near the bot; give the bot materials; run `craft`; then `tools.craft_drift run` while Luis crafts once to measure craft time, processing time and fuel burn.
- **Direction change (Luis, same day): no emulation.** The emulated `craft` (Lua store consume/grant) was removed before it ever ran live; `craft` answers `not_implemented`. Kept (route-independent): the catalog + generator, `recipe_data.lua`, pure `plan`, read-only `craft_check` / `recipes` / `stations`, the unlock mirror. `craft_drift` became a real-craft capture: it now also hooks the move/split/fill/repair/masterwork/interaction RPCs and reports the RPC sequence (`real.rpcs`). DISCOVERIES "Crafting: the real player path" lists the RPCs from the dump (`Server_CraftRecipe` for crafting stations; item moves + `Server_ToggleProcessing` for processing stations; `ECraftingResult`). Tests: `test_crafting.lua` 18, includes a no-emulation guard.
- **Next (crafting):** Luis builds a Crafting Table (and later a Furnace); `tools.craft_drift run` while he crafts once records the real path and checks the catalog. The real-client body will call that path.

### 2026-10-25: gather skill (task P7.1, in progress), woodcutting live, then stopped on Luis's direction
- **Built (route-independent, kept):** services `mod/body/sense.lua` (census, foliage conversion, relocate, generic `look`), `watch.lua` (timeline recorder), `hitcheck.lua` (tool-gate hooks + the damage-cache hook `Multicast_SendDamageCacheData`), `reach.lua` (attack hitbox window + aim solve from `TimedDamageShapes`); data `resource_profiles.lua` (oak, ash, willow, maple, stone, rune essence, guessed metal ores; tool tiers/multipliers checked against the catalog); loop `gather.lua` (beehive BT: scan with widening -> approach -> settle -> aim -> swing -> state chain felled -> splittable -> log -> drops -> stump last -> collect via `body/items` + `body/inventory`). Bridge `gather {resource, count, radius?, bonus?, pieces_only?}` (async, `gather_progress`, `gather_status`, `gather_step` events) and `look {radius?, about?, max?}`, get_state `nearby_resources`. Registered in `main.lua` (live since the 14:59 restart). Brain: `GatherArgs.radius`, `GatherProgress` event, `wrong_tool`/`inventory_full` reasons, BridgeClient gather timeout 1800 s, executor verifies gather against the item id the body reports.
- **Live:** felled oaks and chopped logs/stumps through the emulated hit; **6 oak logs gathered end to end** (15:15, 134 s); the bot store holds 14 oak logs. Calibrated Chop/Overhead hit geometry on a standing ash and a fallen log (reach_calib). Found: fallen-log actor origins are stale (aim at `GetMidPointWorldLocation`), swings during MoveTo point the wrong way (settle first), the attack turns the pawn toward `DesiredActionTarget` (UNVERIFIED; fix built, not run). No crash from any gather step (dumps 10; the 14:45 crash was speech_direct).
- **Stopped (Luis, binding):** no emulation shortcuts; the route is likely a real second client. The emulated hit is now **off by default** (`DW_GATHER_HIT=native`; opt-in `auto`), effective at the next restart. The live server still runs the 15:32 gather.lua, where emulation is ON by default; a restart applies the new default. No UHeldEquipmentItem canary was run. Bot left idle.
- **Unfinished:** log-swing drift hypothesis (run reach_calib on a log with `DesiredActionTarget` nil vs set); ground gatherable grant route (none tried); 2H axe pose (needs Luis holding a 2H tool + `gather_probe held`); metal ore rock classes (census near copper/tin); AOreNode veins (no HealthComponent).
- **Tests:** `mod/tests/test_gather.lua` (23), `tests/test_lua_gather.py`, `tests/test_gather_data.py`; full pytest green.

## 2026-10-25 evening: real-player route (R2) gate 1 passed
- Luis decided: no emulation; Claude must use real player code paths (docs/design/real-player-remediation.md).
- Installed Steam on the VM, logged into Luis's account (temporary, for feasibility), and installed the client (44 GB on disk).
- The headless client (`-nullrhi`) runs beside the server. It needs 1.86 GB and 1.2 cores in world; the VM is left with 1.2 GB free, so 16 GB RAM is advised.
- UE4SS and the DWClient command runner work on the client.
- Through the menu's own API: created the character "Claude", signed in, joined the dev server. The server shows the player "Claude" entering the world.
- Agents' emulation work stopped:
  - crafting emulation removed;
  - gather emulated hit off by default;
  - the remaining puppet systems (inventory store, magnet, shelter spawn, speech relay) are still live until R2 replaces them.
- Next:
  - Gate 2: inject input (jump/move) and verify Luis sees it. This needs a second viewer: Luis's account is in use by the bot client, so he can't join from GFN at the same time.
  - Buy and create Claude's own Steam account.
  - Gate 3: real axe and chop.

## 2026-10-25 19:15 â€” R2 wave status
- Verified live on Shockbyte as the real player Claude:
  - joining, walking and jumping, chat both ways, collecting items, equipping (Luis confirmed visually), death and gravestone recovery (twice);
  - eating and drinking (dehydration killed him twice; the stay-fed reflex fixed it);
  - the brain driving him from chat.
- Learned:
  - PlayerGuid = Steam persona;
  - a new character plays a narrative intro;
  - dehydration kills;
  - character data is server-side on dedicated servers;
  - the client can hang under memory pressure (needs 16 GB).
- Running agents: locomotion v2 (local trace planner), bridge (look/inspect/interact and events), combat and arbiter.
- Roadmap: docs/tasks.json, ids R2.1â€“R2.25 (append-only). Design docs: real-player-remediation.md, research/2026-10-25-client-side-botting.md, research/2026-10-25-traversal.md.

## 2026-10-25 ~21:45 local â€” state snapshot before context compaction
**Live now:**
- Claude's headless client is on Shockbyte as the real player "Claude".
- The character was re-IDed with Luis's edited stats: total level 1076, Agility/Attack 99. GUID A8642C53â€¦; the old GUID's server copy overrides on rejoin.
- The client watchdog is running.
- The freeze fix is in: tickguard plus the 30 fps cap.
- The brain was restarted with the new batch: manifest-driven primitives, event broker, single voice, information-only grounding, activity memory, lookup/knowledge.
- The nav-only dev server and the nav_oracle helper are running.

**Verified live today (real player paths):**
- join; walk, follow and jump;
- chat both ways;
- collecting items, recovering the grave, equipping;
- the stay-fed reflex;
- woodcutting (5 ash) and mining (8 stone);
- combat: Goblin Runt killed, blocks, 0 damage;
- crafting: Community Cape crafted and worn;
- the church-exit route learned.

**Pending/next:**
- Luis to ask in chat: "cast a shelter on flat ground and sleep" (autonomy test; the spells agent is watching).
- Combat round 2 ("go defence": parry/dodge/disengage-heal, overhead chop): needs the sword and shield equipped (he now has a Wooden Training Sword + Anti-dragon Shield).
- Double-jump calibration (move_calib).
- Item stats + comparison in perception.
- Dropped-by perception.
- The scenario suite live run (needs Luis's break).
- Processing-station crafting.
- Windstep via wheel slots 9-12 (gamepad path).

**Agents still active (resume via SendMessage):**
- ad944â€¦ capability contract/skills/perception;
- a1c1aaâ€¦ locomotion (water cost, low-obstacle jumps, calibration);
- a0b192â€¦ combat (defence round);
- ae9335â€¦ spells (shelter/sleep);
- aabcc7â€¦ traversal learning;
- aa990dâ€¦ reviewer (design notes);
- aae572â€¦ crafting, a1a836â€¦ broker, aaebdfâ€¦ knowledge, ae688fâ€¦ scenarios, af4712â€¦ hang: finished.

**Binding principles:** docs/design/PRINCIPLES.md; CLAUDE.md section 0. Roadmap: docs/tasks.json (R2.*, S.*). Streamline plan: docs/design/streamline-plan.md. Review: docs/reviews/2026-10-25-north-star-review.md.


## 2026-10-25 22:00â€“22:45 UTC: /goal started (GOAL.md, milestones M1â€“M6, dev world only)
- **Done:**
  - Claude moved to the DEV world as the dedicated character **ClaudeDev** (`client_io/state/character_name.txt`).
  - `logs/state/client_default_target.txt` = dev; `client_forbid_targets.txt` = shockbyte.
  - The boot and watchdog refuse forbidden targets and leave a forbidden server they land on.
  - The joined-server check survives a stalled game log.
  - The judge-guard hook is installed but inactive until Luis tags the judge baseline.
- **Incident L23:** ClaudeDev was on Shockbyte for about 40 s (main's default-target bug); fixed, with real-boot regression tests.
- **False patch alarm:** client build 26162923 vs server 26161880 is the same version (Net CL 254097).
- **Committed:** Director waves 1â€“3, benchmark v1 + goal_check v2, observability, spend guard, needs/map memory/explore, the spell 'for' field, defence pre-casting (offline).
- **Next:**
  - the eval agent verifies bench_probe â†’ referee â†’ fixtures on dev, then fills the goal cases (for Luis's approval and judge tag);
  - Director wave 4;
  - the broker applies the Director hooks;
  - first T0 benchmark run on dev.


## 2026-10-26 07:08 UTC: first GOAL-loop iteration (M1, T0 smoke on dev)
- **Measure â†’ fix â†’ re-measure:** 2/6 â†’ 3/6 pass, with 0 measurement errors. Latency p50 4.2 â†’ 2.7 s and worst case 12.8 â†’ 3.5 s.
- **Fixes that worked:** L25 (settled cast replies), L26 (stable foliage ids), L27 (cold-start warm-up), and the observer timing fix.
- **Still open:**
  - Axtral: the harness can't see its sub-second projectile, so the referee now polls spell actors; re-running.
  - Phase Dash: honestly unverifiable as a T0 cast; measured in spell-use instead.
  - Eye of Oculus: needs specific evidence data.
  - Latency: p50 is 0.2 s above target.
- **Process change (Luis):** never idle (GOAL Â§2b), a 2-hourly cadence check, and standing approvals for agents. A 7 h stall overnight was main's blocking question.

## 2026-10-26 Director: /simplify applied + chained steps + live smoke run 1
- /simplify items 1-16 applied:
  - plan_key and a separate director_window.json;
  - one progress budget per task;
  - advisories as one non-repair round;
  - knowledge gaps go to KnowledgeMemory only;
  - fileio is used throughout;
  - Planner uses json_decision;
  - `effects_of` adapter;
  - on_player_command(text);
  - the model judges "stop";
  - autoflush=False with one write per tick;
  - pruned per-task dicts.
- Chained transitions (â‰¤8 per tick, never during chat): the step-to-step gap is under 1 s at 1/30/300 s ticks (test).
- Live smoke run 1 on dev: see DISCOVERIES "Director live smoke, run 1". Research, plan, verified runs, replan and the budget window all work. The job never finished: its done test was unsatisfiable (gained+lost). That is now a repair, and Haiku runs ahead of the step (instruction added).
- Next: smoke run 2 after the voice fixes ("EMPTY" spoken).

## 2026-10-26 Director: M3 curriculum facts (every skill on his own initiative)
- The curriculum facts list his skills lowest first. Each skill comes with how it is trained, its XP recipes and the tools that name it, all from data:
  - how it is trained: the wiki skill page's in-game line (`knowledge.skill_pages`);
  - its XP recipes: from the game data;
  - the tools that name it: the body manifest's own descriptions.
- `skill_gain` now takes an `xp` option.
- GearWorld got XP for every skill, using the catalog `range_type` for combat skills, plus fish and agility_course with the real descriptions.
- Results:
  - All 12 frozen skills pass on the mock (tests/test_director_skills.py), with the lagging skill gaining the most XP.
  - With a tool missing, the lagging skill becomes a named gap.
  - Real Sonnet, 10 requests, picked the lagging skill in all 3 cases:
    - Ranged: makes arrows first;
    - Runecrafting: at the altar;
    - Agility: on a course.
    The cassettes are in tests/fixtures/director_cassettes/m3_*.

## 2026-10-26 Director: M5 long self-directed session on the mock, measured
- brain/mock/sim_session.py runs one open Brynmoor session in simulated time:
  - game time is the clock; Haiku costs 2 s per call and Sonnet 4 s per request; polling every 0.25 s;
  - log rows use that clock, so tools/obs_tasks metrics work as they do live.
- The session goes chop â†’ chest â†’ 3 copper trips (60 copper in his chest) â†’ plot â†’ dig+plant â†’ grinder+kiln â†’ wait for the crop â†’ harvest â†’ flour â†’ bread. It ends by choice after 504 s of simulated time.
- Biggest waste measured: waiting for the crop re-ran the Controller on every poll (58 runs; 99 Haiku calls in the session).
- Fix: a `wait` step field chosen by the model.
  - The board re-checks the test each tick with no Controller run.
  - It fails the attempt after WAIT_MAX_S (30 min) so the model replans.
  - It logs `board_wait_start`.
  - Result: 41 Haiku calls. Real Sonnet (3 requests) used wait:true for "Let the wheat grow" (cassette farm_and_process_crop).
- Gaps after the fix: p50 2.0 s, p90 2.25 s, all of it the Controller's first turn on each step. Idle is 26%, all of it the crop growing.
- Next gap lever, not built: let the Director give a step's first call, run before the Controller turn (needs an Agent.run_directed hook). Ordering work during waits is the model's choice.
- First calls (same session, simulated time; brain/mock/sim_session.py):
  - The Director's plan may give a step's `first_call`. It runs at once through Agent.run_first_call, which uses the Controller's own gates: offered tools, schema, safety.
  - When the step already passes on that call, there's no Controller turn, except on the job's first step or when something must be said.
  - Otherwise the Controller carries on from `first_call_result`.

  | | gap p50 | gap p90 | Haiku calls | Sonnet requests | wall |
  |---|---|---|---|---|---|
  | before (no wait, no first_call) | 2.0 s | 2.25 s | 99 | 4 | 504.5 s |
  | wait steps only | 2.0 s | 2.25 s | 41 | 4 | 504.2 s |
  | wait steps + first_call | 0.0 s | 2.0 s | 11 | 4 | 444.2 s |

  - Idle is 30%, all of it the crop growing; longest non-wait idle 0.25 s. Wait steps count as `step wait` in obs, not dead time (observability agent).

## 2026-10-26 Director: first_call with real Sonnet + preconditions from a fresh character
- **Real Sonnet** (5 requests; cassette mining_run_home_chest):
  - It set first_call on 2 of 4 steps: buildables (a read, so the Controller turn does it) and gather {"kind": "Copper Ore"}.
  - The gather args are wrong: the arg is `resource`.
  - Root cause: the Director's tool list had descriptions only, with no argument names.
  - Fixes:
    - the tool list now shows each tool's args from the manifest (`gather(resource*, count*, â€¦)`);
    - the Validator checks first_call args against the tool's schema and sends a mismatch back for repair with the reason.
  - The cassette replays as "rejected since".
- **Preconditions on a fresh dev character**, checked against the real knowledge index (tests/test_director_preconditions.py).
  - Reachable from data:
    - Crafting Table: 4 Ash Logs;
    - Stone Pickaxe;
    - Bone Pickaxe for copper and tin (tier 2);
    - Wooden Spade: Ash Logs + Coarse Thread;
    - Coarse Thread: Spinning Wheel, flax or coarse fur;
    - Spinning Wheel: unlocked by the first flax;
    - Farming: opened by Growing Pains;
    - Kiln costs: clay, fire runes;
    - Grindstone costs: granite, iron bars.
  - Gaps, as strict xfails:
    - the kiln and grindstone unlock sentences don't reach the top 5;
    - no data names the home-chest storage piece or its unlock (dev: no chest unlocked).
  - buildables is now readable during Director research (PROXIED_READS).
- Unlock recall closed at the root:
  - At index build, brain/knowledge.py `unlock_facts` lifts each wiki page's "...unlock..." sentences, from any section, into an `Unlock` doc of its own (SCHEMA 8).
  - Now found: the kiln ("receive clay"), the grindstone ("receive granite"), the spinning wheel, and the home chest.
  - Home chest: the wiki Storage page leads to the player-built chests. The Small Chest ("Ash Chest", build dump BUILDPIECE_Chest_Small) costs 16 Ash Logs + 2 Coarse Thread. It unlocks with the first ash logs plus the Construction perk Creature Comforts.
  - Alternatives: Crate (10 Ash Logs); Oak Chest (unlocks with the first oak logs).
  - Both xfails now pass. Sticks stay open until live.

## 2026-10-26 Director: M6 Vel'gar curriculum (data/curricula/velgar.json)
- The milestones in docs/design/velgar.md Â§4 become jobs with done tests, queued with `tools/board.py curriculum`. Inbox add records now carry `success`.
- New predicates: `spell`, and `vital` max_at_least / max_gain_at_least.
- On the mock (tests/test_director_velgar.py) a stand-in planner reads only its research results: craft_plan, compare_gear, the creatures and usable things in sight. With it, 7 of 9 milestones run to done:
  - Challenge Horn, Anti-Dragon Shield, 20 Lesser Antipoison, 20 Berry Drizzle;
  - the PL 4 kit, crafted and worn;
  - 5 Sanguine Urns (+50 max HP);
  - Attack 8.
- Real Sonnet, 3 requests (Lesser Antipoison): craft_plan research, then Pottery Wheel â†’ Kiln â†’ Brewing Cauldron, with correct first_call args.
- Fixes on the way:
  - mock craft_plan no longer "crafts" from traders (knowledge.vendor_station, shared);
  - mock craft_plan avoids cyclic recipes;
  - the Director's state shows only living creatures (with ids) and usable things.
- Gaps:
  - no get_state.spells list in the client (spells.lua has no state_extras);
  - Enchant Weapon: Air needs Attack 30 (wiki perk), well beyond the Attack 8 milestone;
  - the Dragon Slayer step texts are unknown until live;
  - vault/fight drops (Vault Shards, Opals, Dragon Tooth, Bloodwood Sap) aren't simulated.

## 2026-10-26 â€” Codex recovery status

- Recovered original goal, transcripts and late live results; pushed recovery snapshot 7921ff5 and history to origin/main. Preserved runtime memory in a private local archive and adopted the existing dev processes.
- Implemented and focused-tested speech protocol repair, FX reference/token checks, test-fixture/debugger portability fixes, and movement ownership plumbing. Regenerated places from all 31 live region tags. These are infrastructure and correctness improvements; Windstep execution and autonomous task evidence remain pending.
- Fresh full regression run: `logs/recovery/resume-check-d9d6a5820c534a45b9f0e432b147f876/check-all.log` (result pending at this entry). Earlier corrected baseline was 6 failed / 1045 passed / 1 skipped; focused tests for its failures now pass.
- Survival diagnostic was ignored by addressed-chat routing because its text omitted `!c `: zero model calls, no gameplay improvement. Correct diagnostic routing before re-measuring. Daily API spend remains governed by the shared $10 UTC-day cap.
- No fresh M1â€“M6 success claimed; planner responsiveness, traversal, survival and no-axe proof remain outstanding.
- Full rerun finished: 1053 passed, 2 failed, 1 skipped. The two failures were WinError 5 during atomic test-state replacement; both passed immediately in isolation. A final full run is needed before GREEN. Created the requested five-hour continuation schedule in this thread.

## 2026-10-27 â€” Recovery checkpoint verified

- **CHECK_ALL: GREEN: 1057 passed, 1 skipped**, full suite on the corrected source (387.55 s). Private log: `logs/recovery/state-fixed-check-d1c78face399405685b82f4f7d293bfc/check-all.log`.
- Reused the shared Windows-safe atomic writer for task-state persistence; regressions prove recovery from temporary denial and preservation/error propagation on permanent denial. Fresh Terra design and code review clear. Confirmed workspace Modify access and full owner access to the failed files, plus 50 successful probe replacements in that directory; no additional elevation required.
- Approved judge diff is empty. Recovery fixes are ready for a coherent Git checkpoint; live FX/survival and unfinished traversal/planner work remain pending. No M1â€“M6 completion claim.
- Requested five-hour continuation is ACTIVE in this thread (`resume-dragonwilds-companion`). Current UTC-day game-model spend read $0.00 / $10, zero calls; account five-hour allowance reset, latest reading 3% used.

- Follow-up wave: board-result continuation and bounded Windstep executor implemented with independent reviews and regressions. **CHECK_ALL: GREEN, 1061 passed, 1 skipped** (379.17 s). Specific cast/landing failures remain explicit; live performance and calibration pending. All 40 queued live-check definitions validate; dev target and Shockbyte prohibition confirmed. Main reserved the idle client while testing.

- Pushed that wave as b9d2015. Fresh FX run: two existing checks passed, enchant failed busy/fighting; same process token throughout, Splinter still interrupted/uncovered. No broad FX completion claim.
- Fresh capped survival diagnostic: 6 Haiku calls / 0 Sonnet, $0.0050. It fought, gathered food and drank, but **died to a Goblin Runt and did not rest**. Failure retained in the handoff; no goal milestone credited. Investigating escape continuation and defense evidence.
- New dirty-tree work: calibration integrity/provenance reviewed and targeted-tested; water gain attribution fixed with 60 capability regressions passing and cold review clear; flee continuation under final review. These changes still require a fresh full gate and live remeasurement. No judge changes or memory resets.

## 2026-10-27, 15:13 Berlin â€” Survival fixes verified offline

- **CHECK_ALL: GREEN, 1067 passed / 1 skipped**, 454.32 s. This includes calibration integrity, actual-source water reporting, bounded escape continuation and true failure activity. Focused suites: 60 skills, 396 combat/arbiter; independent reviews complete. Live remeasurement remains pending.
- Repaired the final interrupted gate's bare scenario lease replacement and reused the shared writer for client-slot/live-queue state. Six denial-injection regressions and 38 focused operations tests pass; existing data is preserved on permanent denial. Approved judges unchanged.
- Confirmed the five-hour schedule did start at 13:01, but the app rejected it for account usage until 13:05. Updated scheduled instructions for allowance checks/checkpoint margin; Goal mode is separately paused. No automatic-retry guarantee. Current task resumed on Luis's instruction.

## 2026-10-27, 15:55 Berlin â€” Live attribution and service adoption

- Water regression passed its second allowed attempt: correctly named Dirty Water, actual source, independent inventory +2; first attempt path-blocked retained. Calibration remains unmeasured after readiness refused uneven/obstructed ground. Memory backed up beforehand; no envelope created.
- Manual use of existing service APIs refreshed stale callbacks, preserving policy/orders; native reflex then drank carried water and verified hydration 0 -> 19.54. Added the general supervisor adoption correction with pending failure/backoff and idempotent existing-loop reuse.
- **CHECK_ALL: GREEN, 1067 passed / 1 skipped**, 386.40 s; focused bridge tests 11 passed. Automatic native adoption and a short M1 pilot are next. No two-hour exposure/stability or overall-goal completion claim.

## 2026-10-27, 16:16 Berlin â€” Native adoption and short M1 pilot

- 7c6a2e2 is pushed; automatic native adoption now verified with all six services current and no duplicate fed/guard loop. Global policy/orders preserved. Full gate remains 1067 passed / 1 skipped.
- Five-minute A1 pilot completed; chat/health proof passed. Actual water collection, hydration increase, berry gathering and eating observed. Three scheduled chats plus proof; latest A1 p50 9.0 s / p90 9.92 s, n=4, so latency targets remain unmet. Exposure 0.102 h is insufficient for M1 stability. Top-level report also includes old phases; preserve that distinction.
- Found command/reflex consume input overlap; R14 is open. Reviewed generic transaction design precedes implementation. Stale grave targets, failed interaction and interrupted actions also remain in evidence.
- Pilot used 29 Controller, 3 Director and 1 warmup request; $0.096 incremental, UTC-day total $0.101 / $10 (39 priced calls). Runner brain stopped, reservation released, native client idle in dev. No game/client/Steam restart and no world memory reset. Low RAM was observed; single-heavy-workload rule retained.

- Fresh bounded pilot window (15:03:41â€“15:10:40 UTC): 0.111 active hours, 21 world-changing calls, zero measured crashes/deaths/stalls. Companion bridge and fed/guard loops then stopped through normal cached APIs at an idle boundary to prevent automatic adoption of incomplete source edits. Game/server remain running; policy/orders retained. Explicit offline gate and controlled rearm required.

## 2026-10-27, 16:25 Berlin â€” Unfinished candidate saved before allowance exhaustion

- Account 95% five-hour used, 46% weekly; reset 19:59 Berlin. Delegation stopped. Tested main evidence checkpoint 139d2a0 pushed; unfinished consumable candidate stays in working tree with private patch backup, not presented as tested or pushed source.
- Initial targeted green candidate failed cold review on transaction expiry/duplicate input, unknown readings, stale reflex baselines and insufficient real integration coverage. Partial revisions remain unvalidated. Recovery handoff lists exact next steps.
- Companion services stopped and dev client held through existing stop_client.ps1 -Hold while offline code is incomplete; Steam/dev server retained. This is an agent operational hold, not a human pause. Resume offline checks first, then announce/release/relaunch dev client only after approval by tests/review. M1â€“M6 remain unmet.

## 2026-10-27 evening â€” Consumable ownership integration

- Goal is active and account allowance permits work again. One bounded fresh Terra finished the coupled inventory/skills/combat lifecycle; a separate reviewer approved the revised candidate after pause, owner-loss and unreadable-inventory findings were fixed. No live result yet.
- Shared transaction binds owner and item, accepts one input, preserves an interrupted press through its existing verification window, and does not expire an uninterrupted live waiter. Command, fed-reflex and combat uses share it; raw consumable use/equip cannot bypass it. Unknown readings are unverified, not fabricated success or bad-item strikes.
- Regressions include real bridge/skills/inventory/arbiter/reflex overlap, stop, pause/unpause, modal ownership and abandoned-gate expiry. Combat suite has 400 checks; some combat interruption fixtures use fake inventory transactions, while the bridge and lost-owner fixtures use real modules. Focused Python wrappers: 20 passed.
- First full gate: 1066 passed / 1 failed / 1 skipped, 386.88 s. Only failure was the design note's missing exact Search record heading; actual searches/sources were present. Heading corrected and all five design-note tests pass; full rerun in progress. Record its actual result before deployment.
- Fresh memory backup before planned live work: logs/recovery/memory-before-consume-live-20261027T185613Z.zip (13 files, 45214 bytes). Dev client remains held; Steam and dedicated ClaudeDev configuration verified. API spend unchanged at $0.101 UTC-day, with no API calls during offline work.
- Full rerun **CHECK_ALL: GREEN, 1067 passed / 1 skipped**, 366.77 s. Log: logs/recovery/consumable-full-fixed-7862886332dc4ac2b4ed55906acf70d9/check-all.log. Frozen judge diff empty. Native deployment and remeasurement are next; no survival or M1 completion claimed.
- Pushed 62e7f81; client relaunched first attempt on dev, Steam retained. Native queue 20261027-201444: water collection first-attempt pass; food first deferred busy/pending verification, then configured retry verified Bread use (sustenance 33 -> 63, count fell, gameplay input). Transaction afterward idle, no action/waiters, background services running. This verifies directed mechanics; autonomous self-care/no-axe and M1â€“M6 remain pending. Existing test setup restored health from 1 to 100; that is harness preparation, not autonomous healing.

## 2026-10-27 evening â€” Autonomous measurement and false goal completion

- Self-care: 6 Haiku / 0 Sonnet, 48.3s, $0.0042. Own-grave retrieval, eating and drinking increased food35.7->62.4 and water9.8->37; health100 maintained. One consume verification failed then recovered. Endurance0 and no rest action: full task not proved; no new grants during run.
- No-axe task87658e1c FAILED independent audit despite board done: one tool-free stick pickup satisfied the model-chosen AshLogs+1 predicate; zero swings/hits/breaks, no axe/craft/bench, WCXP206 unchanged. Log brain-live-20261027-203109-8512.jsonl; before/after probes preserved. Runtime planner success was too weak; frozen benchmark judges are unchanged.
- Run including old/background jobs used31 Controller /18 Director /1 warmup. UTC-day total $0.4827,95 calls. Owned brain stopped and remaining body action cleared through normal main-channel stop. Client now down/held for next body work; server/Steam/memory retained, freeRAM~3.3GB.
- Primary-source gathering-operation design conditionally approved. PhaseA contract/guidance implementation underway; root-count rewrite deferred pending actual native signals. No no-axe, M1 or broader completion claimed.

## 2026-10-27, 21:23 Berlin â€” Gather contract gated; live throughput priority

- Reviewed Phase A passed CHECK_ALL: GREEN, 1069 passed /1 skipped in366.57s; frozen judge diff empty. Optional gather mode survives typed validation and learned skills, fallback remains available, profile/expected-training labels no longer imply actual operation provenance. No live improvement or no-axe completion yet.
- Stable runtime plus isolated candidate development is the agreed next operating arrangement. One live operator keeps relevant cases moving; client-off publication/resource windows remain bounded. Server never stopped; client relaunch follows this checkpoint.

## 2026-10-27, 21:32 Berlin â€” Concurrent stable runtime and candidate work

- Client relaunched dev and remained available while code was edited in a managed isolated candidate. The real no-axe run immediately found a transport-signature gap missed by schema-only tests; model selected chop, bridge rejected mode. No game action/felling/XP gain occurred. Stopped promptly and preserved task. New adapter regression covers actual Executor to Lua transport.31focused tests pass; full/live fix verification next.
- Native FX enchant queue passed22.3s, zero API calls; setup sword/runes/unlock grants are not autonomous evidence. Noaxe remainsunproved. UTC spend.6067/10,115 calls.

## 2026-10-27, 21:49 Berlin â€” Adapter and isolated candidate verification

- Candidate fullgate GREEN1070passed/5skipped,367.17s. Four dump-signature skips repaired by provisioning the exact private header inputs; four tests then passed. Existing incomplete cassette remains the single intentional skip. New transport regression covers explicit, omitted and null mode through real Executor/JSONL/Lua.
- Separate candidate supports targeted tests while stable dev client stays online. Initial full RED69/1000/6 exposed ignored dependency, path-length and raw manifest EOL portability issues; setup corrected without changing criteria or repinning. Source fix now ready for Python-only deployment and live tree rerun; no noaxe/M1-M6 success.
- Live directed FX held enchant and dirtywater tests passed,0modelcalls. Brain-off exposure showed hp1/nofood; not autonomous maintenance. API total remains.6067/10,115calls.

## 2026-10-27, 22:15 Berlin â€” No-axe pilot and next coherent batch

- Published/pusheda12412a withverifiedunchangedbodybytes; nativegatherfood/water andconsume worked, but noaxe proofFAILED. NewWoodcuttingXPconditiondidnotacceptgrave-lootedlogs. ActualKillZdeathoverlappedfalse2Darrival; preserveworld/graves andreportedfailure. $0.133run,UTCtotal.7397/10,145calls.
- Reviewedqueue,3D/life-arrival andcatalog-categorydiscoverycandidates areisolated; fullgatehasNOTstarted. Batchthem afterfinalnavreviewbeforeonecoherentgate+briefbodyrestart. No M1-M6 completion. Nativecalibrationrefusednonflat55cmspot, nojumps/envelopechange; positivecalibrationstillpending.

## 2026-10-27, 22:25 Berlin â€” Combined outcome/discovery/queue gate

- CHECK_ALL: GREEN1096passed/1skipped,371.46s; approvedjudgediffempty. Queue samePIDreadiness, immediate-onlybusyrefusal, truthfulheight/lifearrival andcatalogcategorycandidates independentlyreviewed andintegrated90focusedchecks beforefull.
- Devclientrestartannounced forbodypublication; stableclientwasonline throughoutdevelopment/tests. ServerandSteamremainadopted. Backups/affectedpathmanifest and44memoryfiles savedprivately. Nativecurrent-codeverificationstillnext; no axe/bench/felling, no fallprevention/M1-M6 claim.

## 2026-10-27 â€” 23:10 Berlin: live-throughput and process diagnosis

- Confirmed one ChatGPT app root with renderer/service children, one dev client/server, no active game brain or leftover test runner. Retained development agents completed. Both game processes normal priority8; app summed working sets about1.6GiB, host8GiB with576â€“1178MiB available during diagnosis. No confirmed orphan killed and no working-set trimming.
- Live operator used queue20261027-230505 for read-only FPS/floor checks:2s active,20s readiness blocked,0 model calls/grants, slot released. Configured client limit30FPS; actual rate unmeasured. Positive jump calibration blocked by HP1/food0/endurance0.5 and unverified route, not by an offline gate.
- Found scheduling gap: pending queue consisted of4 blocked cases; no DragonwildsLiveQueue task in scheduled-task inventory. Keep a single operator selecting relevant ready cases and recording idle reasons. Do not claim a live/offline ratio from spot checks or auto-run legacy fixtures into the autonomous task.
- Saved previously completed cde construction evidence and new R22 mixed plan/help failure in recovery/BUGS/DISCOVERIES. Unlock-information candidate remains uncommitted and unpublished, no new full gate; next implementation is generic Director decision-contract repair, then integrated gate/publication/live resumption. Goal remains active, no axe/felling/M1â€“M6 completion.

## 2026-10-27 â€” Parallel implementation and developer-driven validation

- Luis approved offline checks -> developer-driven real-client validation -> unassisted Haiku. Recorded in AGENTS; sessions explicitly retain driver/setup provenance.
- Root directly used the table, crafted/equipped a Stone Logging Axe and felled a real tree on deployed cde. Native item/material/Artisan and Woodcutting changes verified; no model API calls. Assisted tree trial parked with backup rather than falsely counted unaided.
- Two bounded Terra implementation streams ran in an isolated interaction worktree while the primary candidate was frozen: UI interaction ownership/verification and precise rest perception. Independent reviews approved both. A separate recipe-card regression correction preserved unchanged real-data quantity checks and bounded context.139 integrated focused checks passed.
- First gate62459 ended RED1/1116/1skip due verbose unlock fields displacing the ore recipe. It was corrected with atomic detail fields/schema11,18 knowledge and5 design checks passing. Current integrated gate62885 is RUNNING in logs/recovery/cf-aa9ea208/check-all.log; no Green/deployment claim yet.
- Developer-native Summon Shelter and daytime-rest controls verified shelter effects and endurance33->54 over20s with sleeping/timeframefalse. Declared health/nutrition/time fixtures, no endurance manipulation. Exit returned got_up/Gameplay. R24 false path_blocked while already resting is separately recorded and not repaired in this candidate.
- Current runtime remains cde, no brain or live tester. Last API spend0.9880/10 with197 priced calls; subsequent direct diagnostics0 model calls. Both original pilot tasks parked as assisted. Full fresh no-axe chain and M1â€“M6 remain unmet.

- Integrated gate62885 completed GREEN1126 passed/1 skipped in378.54s. Fresh UTC spend scan confirmed0.9880/10,197 calls,0 unpriced. Source frozen; main announced client-only publication restart, with server/Steam/world memory retained. Native candidate remeasurement follows deployment.

## 2026-10-28 â€” Deployed528ae99 and completed validation cycle

- Source checkpoint528ae99 pushed/deployed afterGREEN1126/1skip; all24 affected bytes verified, world memory/SQLite backup preserved, server/Steam retained through client-only restart. New ClaudeDev client11752. Native developer tests now pass both crafting and processing menus: correct owner, one press, screen_opened, clean Gameplay.
- First2-call Haiku pilot exposed an unpumped diagnostic queue. Private corrected harness passed5 offline regressions and independent review; it then executed model-selected work in the real client.
- Corrected pilot10Haiku0Sonnet collected3 berries; reflex consumption contributed to health/food/water gains. Water failed too_far and artificial planner cap0 prevented repair; no complete survival, rest or fresh-goal proof. Both pilots terminal, body idle, slot released; final UTC spend1.0021/10,209 priced/0 unpriced.
- R24 design ready/approved contingent on verified getter ABI/read-only contract; no body implementation yet. Original no-axe chain, positive calibration and full M1â€“M6 remain active/unmet. Next failure-recovery pilot must use appropriate planner allowance and disclose assisted starting state.

## 2026-10-28 â€” Compound-request diagnosis and parallel follow-up

- Prepared/reviewed private planner4 diagnostic, retaining 20 Haiku controller / four total Sonnet planner caps and unchanged production/judges; seven focused harness tests passed. The live run ended naturally in188.4s, five Haiku/zero Sonnet calls, +$0.0039. Native food0->49.3 and health1->12; water stayed0, endurance60.9->58.5, no sleep. No fixtures/hints/restart in this run; prior assisted-world provenance remains.
- Trace proves the direct chat chain hit MAX_TURNS=4 (initial action plus four continuation turns) after gather/consume, without model completion or pending goal. A later continuous agent might react to other events; that was not measured by this finite harness. Generic deferred-continuation design was independently reviewed/narrowed; isolated W implementation and targeted tests are in progress, not deployed.
- Root developer water check on unchanged528ae99 collected one Dirty Water through real bank approach/interact and native inventory+1. Body reflex_use ts1793145368 consumed it; subsequent boiling correctly reported missing_materials with0 Dirty Water. This is capability/reflex evidence, not an autonomous compound pass. A separate collect-six/boil-one developer check is running as live-queue exec17686; adopt its actual handle/process rather than duplicate it.
- R24 protected pointer observation establishes a zero wrapper address with stable pawn/component in Gameplay. CDB raw comparison was denied with Windows error5; no memory inspection/patch/restart. Prerequisite parked, no R24 implementation. Native world memory retained.
- UTC2026-10-27 ended at last measured$1.0060/10,214 priced/0 unpriced. UTC rolled to28 during zero-API native work; read the new day before further model calls. Development account ordinary usage allowed at18% weekly used. Goal remains active, original full unaided no-axe chain and M1â€“M6 unmet.

- Developer collect-six/boil-one queue010040 passed primitive chain39.7s:6Dirty Water collected; real Campfire used1Dirty Water +1carriedAsh fuel and yielded1Clean Water; Cooking107->108. Main reflex_use1793145682 drank Clean Water; later native hydration38.1. No fixtures/API calls; pre-existing campfire/earlier assisted world disclosed.
- R10 positive calibration queue010539 passed39.1s: three179cm singles, validated double pairs295/295,313/313,322/323cm at0.25/0.33/0.40s. HP100 before/after. Saved verified single1.64m/double3.07m/delay0.40s with safety margin, prior empty-envelope directory backed up. Reader queue010945 independently confirms both measured fields. Original status-only reader attempt failed because an already-arrived move had no computed envelope; evidence retained. No Windstep/obstacle-traversal/fall-prevention claim. Raw envelopes now explicitly ignored per existing preservation policy.

- R25 candidate cold review approved after correcting provider/action handoff races, reentrant ownership, ignored ambient chat and partial multi-action resumption.163 focused checks passed; full gate99723 TERMINAL GREEN1156 passed/1 skipped439.72s, log cf-a53d59a5/check-all.log. Approved judge diff empty. Source remains W-only until brain-only publication; all95 recorded loaded source files and installed entry must stay unchanged, no client/Steam restart required for Python-only update with no running brain.

- Checkpointa388437 pushed/deployed brain-only with14exactpaths and95loadedsource+entry unchanged, no game/Steam restart. Developer actualtrace proves6successfulgo_to actions across old5-action boundary; nativeidleafter27.67s. PrivateV1 capturehook was wrong, so independenttrace pairs are authoritative. A6-line episode-context follow-up plus regressions is cold-approved/121focusedpass; fullgate57615 running, not yet GREEN/deployed.
- Unassisted Haiku continuation-aware pilot86.7s,6Haiku0Sonnet,$0.0073 onUTC28, ended by realKillZ beforecontinuationboundary; no survival/continuationpassclaimed. Game naturallyrevived100HP, currentreadalive; runesretained/axeabsent, no save/inventory restoration. Source/logs distinguish actualcurrentgrave from stale remembereddeathposition; generic forward-floor safety remains openR26, exactphysicscauseunknown. AllAPIbrains/testersstopped/slotfree.

- Episode-attribution follow-up fullgate57615 TERMINAL GREEN1157passed/1skipped374.22s;121focused checks and fresh coldreview preceded it. Saving/restoring original logger context also preserves nestedambient/outer context. Ready for separate metadata checkpoint and developer-v2 trace verification on freshly observed local terrain; no second Haiku retry of the fatal route.

- Source6da33fe pushed/deployed after finalGREEN1157/1skip,95loadedfiles+entryunchanged/no game restart. Developer-v2 actual6successfulrequests,5beforeyield/6thafterpump, allrawaction/resultsameepisode and captureagreement,28.61s/0API. Alivebefore/after butHP1->0.5; no survivalpass. FinalreadonlyR26floorbaseline nowqueued88580 beforehandoff; substantivefloor/ledgeguardstillnotimplemented.

- Final R26 read-only baseline queue014058 completed observed,3.4s active/10s readiness wait,0API/no inputs. Dry mode1/depth0; centre-to-floor92.14cm vs capsule half-height88cm; reported penetration true remains ambiguous. Two Custom side hits matched Visibility at this site, not general profile validation. HP0.5 unchanged. All runners terminal, no body action/waiters, slot free; raw measurements preserved for the next safe forward-support design cycle.


- 2026-10-28 01:22 UTC: R26 sensor investigation advanced on unchanged deployed source7e5925e. One current-position typed posthook query (queue20261028-022154,2.3s active) copied mask-aware flags matching CurrentFloor, where copied Lua-table flags had contradicted it. No movement, restart or API; HP0.5 unchanged, identities stable, body idle. Subscriber removed; native hook remains dormant until restart. This verifies one read path, not lookahead, safe braking or the fatal geometry. Research/source/live evidence: docs/research/r26-floor-observations-20261028.md. Private release sampler94checks passed after cold review found/corrected paused native timer cancellation; adapter private implementation next, stationary-only before any input. Two bounded Terra assignments used; one native operator.

- 2026-10-28 01:26 UTC: separately cold-reviewed native snapshot adapter observed successfully once (queue20261028-022558,2.2s active/14s readiness). Exact floor/capsule/velocity/identity/native survival getters read; no input, sampler, timers or lease. HP0.5,food/water0,endurance2.806 means movement remains inappropriate without fresh resource setup. Independent dev guard and idle verification passed;0API. Design-note checks5passed; no production code changes, so prior source gate remains unchanged rather than claiming a new full regression.

- 2026-10-28: R26 advanced to nine typed nearby queries and a first real input/release pilot (queue20261028-024427). One input moved1.392664cm, HP100 unchanged, stable observed, cleanup acknowledged and slot free, zero API calls. No full-speed braking, fall-prevention or autonomous pass. Private sampler113 checks now records release velocities, not yet live. Research/recovery notes record actual timing, watchdog correction, assisted supplies and SHA256 archive.

- 2026-10-28: added the standalone disabled native floor reader after design/cold review,33 actual-hub assertions and GREEN1158/1skip (382.51s). One explicit stationary source smoke succeeded with no additional native registration and owned cleanup. Staged walking reached450cm/s release and observed7.399cm horizontal post-release on one slope, HP100 retained; no general braking/prevention pass. The8-input overrun result remains partial. Next is actual support-guard integration with traversal-phase handling, not more stationary compatibility work.

- Published source5cf1c8a additively:383 existing runtime files SHA256-unchanged, no restart or normal enable; current companion/body hashes0263243d9b28900f/ee34af4478a8b40a. Frozen judge diff empty. Publication/native source digest preserved; earlier pulses remain prior-hash diagnostics, not GOAL scores.
